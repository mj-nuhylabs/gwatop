"""OpenAI Structured Outputs(strict json_schema) 헬퍼 + 안전한 폴백.

배경
----
기존 모든 생성기는 `response_format={"type": "json_object"}` (구형 JSON 모드)를 썼다.
JSON 모드는 "유효한 JSON"만 보장할 뿐, **스키마(필드/타입/구조)는 보장하지 않는다.**
그래서 코드 곳곳에 방어 로직이 쌓였다 — Pydantic per-item 검증 후 스킵, 마인드맵
문자열→dict 강제 변환, "유효한 X 없음" 예외 등.

Structured Outputs(`response_format={"type":"json_schema", ..., "strict": True}`)는
모델이 **스키마를 100% 준수**하도록 디코딩 단계에서 강제한다. 필드 누락·타입 오류·
추가 산문이 원천적으로 불가능해져 생성 실패율이 급감한다. (gpt-4.1-nano / 4o-mini /
4o-2024-08-06+ 모두 지원.)

안전장치 (프로덕션 무중단 원칙)
------------------------------
1. `settings.OPENAI_STRUCTURED_OUTPUTS=False` 면 완전히 기존 json_object 경로만 사용.
2. json_schema 호출이 **거부(BadRequestError)** 되면 그 모델을 이 프로세스에서 비활성화
   하고(서킷 브레이커) 즉시 json_object 로 폴백한다. 스키마 거부는 결정론적이라
   매 호출 첫 시도를 낭비하지 않기 위함. (워커는 max_tasks_per_child=80 마다 재시작되어
   주기적으로 다시 시도한다.)
3. 일시적 OpenAIError 면 비활성화 없이 한 번만 폴백.

따라서 어떤 경우에도 **최악은 "오늘과 동일한 json_object 동작"** 이다 — 순수 상향.
호출자는 반환된 raw JSON 문자열을 기존과 똑같이 `json.loads` + 검증하면 된다.
"""

from __future__ import annotations

import logging
from typing import Any, Awaitable, Callable, Type

from openai import AsyncOpenAI, BadRequestError, OpenAIError
from pydantic import BaseModel

from app.core.config import settings

logger = logging.getLogger(__name__)


# strict json_schema 가 허용하는 키워드만 남긴다.
# (minimum/maximum/minLength/maxLength/pattern/format/default/title 등은 미지원 → 제거)
_ALLOWED_SCHEMA_KEYS = {
    "type", "description", "enum", "properties", "items",
    "required", "additionalProperties", "anyOf", "$ref", "$defs",
}

# 한 프로세스에서 json_schema 가 거부된 모델 — 재시도 낭비 방지(서킷 브레이커).
_disabled_models: set[str] = set()


def _strict_node(node: Any) -> Any:
    """Pydantic `model_json_schema()` 출력을 OpenAI strict 규격으로 변환.

    - 모든 object 노드에 `additionalProperties: false` + `required = 모든 키` 강제.
    - strict 미지원 제약 키워드(minimum/maxLength/pattern/default 등) 제거.
    - `properties` / `$defs` 는 "이름→하위스키마" 맵이므로 키를 보존하고 값만 재귀.
    - 재귀 모델(마인드맵)의 `$ref` / `$defs` 자기참조도 그대로 통과(OpenAI strict 지원).
    """
    if isinstance(node, dict):
        out: dict[str, Any] = {}
        for key, value in node.items():
            if key not in _ALLOWED_SCHEMA_KEYS:
                continue
            if key in ("properties", "$defs"):
                # 이름→스키마 맵: 이름(키)은 임의 문자열이라 보존, 값만 재귀.
                out[key] = {
                    name: _strict_node(sub) for name, sub in value.items()
                }
            elif key == "items":
                out[key] = _strict_node(value)
            elif key == "anyOf":
                out[key] = [_strict_node(sub) for sub in value]
            else:
                # type / description / enum / required(list) / $ref(str) 등 — 그대로.
                out[key] = value
        if out.get("type") == "object":
            props = out.get("properties") or {}
            out["required"] = list(props.keys())
            out["additionalProperties"] = False
        return out
    if isinstance(node, list):
        return [_strict_node(item) for item in node]
    return node


def build_strict_schema(model: Type[BaseModel]) -> dict[str, Any]:
    """Pydantic 모델 → OpenAI strict json_schema dict."""
    return _strict_node(model.model_json_schema())


async def run_structured_completion(
    client: AsyncOpenAI,
    *,
    model: str,
    messages: list[dict],
    schema_model: Type[BaseModel],
    schema_name: str,
    max_tokens: int,
    temperature: float,
):
    """임의의 messages 리스트(시스템/few-shot/유저)로 JSON 응답을 받고 **응답 객체**를 반환.

    few-shot 메시지나 prompt/completion 토큰 분해가 필요한 호출(강의계획서 파서)이 이
    저수준 프리미티브를 직접 쓴다. json_schema 우선 + json_object 폴백 + 서킷 브레이커.
    호출자는 `resp.choices[0].message.content` / `resp.usage` 를 기존과 동일하게 사용한다.
    """
    if settings.OPENAI_STRUCTURED_OUTPUTS and model not in _disabled_models:
        try:
            schema = build_strict_schema(schema_model)
            return await client.chat.completions.create(
                model=model,
                temperature=temperature,
                max_tokens=max_tokens,
                response_format={
                    "type": "json_schema",
                    "json_schema": {
                        "name": schema_name,
                        "strict": True,
                        "schema": schema,
                    },
                },
                messages=messages,
            )
        except BadRequestError as exc:
            # 스키마 거부 / 모델 미지원 — 결정론적. 이 프로세스에서 이 모델은 비활성화.
            _disabled_models.add(model)
            logger.warning(
                "structured outputs disabled for model=%s (→ json_object fallback): %s",
                model, exc,
            )
        except OpenAIError:
            # 일시적 오류 — 비활성화 없이 폴백만.
            logger.warning(
                "structured outputs call failed; falling back to json_object once",
                exc_info=True,
            )

    # ----- 폴백: 기존 json_object 모드 (OpenAIError 는 호출자가 처리) -----
    return await client.chat.completions.create(
        model=model,
        temperature=temperature,
        max_tokens=max_tokens,
        response_format={"type": "json_object"},
        messages=messages,
    )


async def structured_chat_json(
    client: AsyncOpenAI,
    *,
    model: str,
    system: str,
    user: str,
    schema_model: Type[BaseModel],
    schema_name: str,
    max_tokens: int,
    temperature: float,
) -> tuple[str, str, int, str | None]:
    """system/user 2-메시지 편의 래퍼.

    `(raw_json_str, response_model, total_tokens, finish_reason)` 반환. 호출자는 기존과
    동일하게 `json.loads()` + 검증을 수행한다. (스키마가 보장돼도 후단 검증은 안전망.)
    """
    resp = await run_structured_completion(
        client,
        model=model,
        messages=[
            {"role": "system", "content": system},
            {"role": "user", "content": user},
        ],
        schema_model=schema_model,
        schema_name=schema_name,
        max_tokens=max_tokens,
        temperature=temperature,
    )
    choice = resp.choices[0]
    return (
        choice.message.content or "",
        resp.model,
        (resp.usage.total_tokens if resp.usage else 0),
        getattr(choice, "finish_reason", None),
    )


async def stream_structured_completion(
    client: AsyncOpenAI,
    *,
    model: str,
    system: str,
    user: str,
    schema_model: Type[BaseModel],
    schema_name: str,
    max_tokens: int,
    temperature: float,
    on_delta: Callable[[str], Awaitable[None]] | None = None,
) -> tuple[str, str, int, str | None]:
    """JSON 응답을 **스트리밍**으로 받으며 각 텍스트 청크를 `on_delta` 로 흘려보낸다.

    구조화 콘텐츠는 JSON 이라 부분 렌더는 안 되지만, 스트리밍으로 호출하면
    (1) 생성이 끝나는 즉시 결과를 전달(Celery 큐 대기·폴링 지연 0) 하고
    (2) 진행 중임을 실시간으로 보여줄 수 있다.

    반환: `(raw_full_json, response_model, total_tokens, finish_reason)`.
    json_schema 우선 + json_object 폴백 + 서킷 브레이커는 비스트리밍 경로와 동일.
    """
    def _create_kwargs(response_format: dict) -> dict:
        return dict(
            model=model,
            temperature=temperature,
            max_tokens=max_tokens,
            response_format=response_format,
            messages=[
                {"role": "system", "content": system},
                {"role": "user", "content": user},
            ],
            stream=True,
            # 스트림 마지막 청크에 usage 가 실려와 토큰 집계가 가능해진다.
            stream_options={"include_usage": True},
        )

    stream = None
    if settings.OPENAI_STRUCTURED_OUTPUTS and model not in _disabled_models:
        try:
            schema = build_strict_schema(schema_model)
            stream = await client.chat.completions.create(
                **_create_kwargs({
                    "type": "json_schema",
                    "json_schema": {"name": schema_name, "strict": True, "schema": schema},
                })
            )
        except BadRequestError as exc:
            _disabled_models.add(model)
            logger.warning(
                "structured outputs(stream) disabled for model=%s (→ json_object): %s",
                model, exc,
            )
        except OpenAIError:
            logger.warning(
                "structured outputs(stream) failed; falling back to json_object once",
                exc_info=True,
            )

    if stream is None:
        stream = await client.chat.completions.create(
            **_create_kwargs({"type": "json_object"})
        )

    parts: list[str] = []
    resp_model = model
    total_tokens = 0
    finish_reason: str | None = None
    async for chunk in stream:
        usage = getattr(chunk, "usage", None)
        if usage is not None:
            total_tokens = getattr(usage, "total_tokens", 0) or total_tokens
        if getattr(chunk, "model", None):
            resp_model = chunk.model
        if not chunk.choices:
            continue
        ch = chunk.choices[0]
        delta = ch.delta.content if ch.delta else None
        if delta:
            parts.append(delta)
            if on_delta is not None:
                await on_delta(delta)
        if getattr(ch, "finish_reason", None):
            finish_reason = ch.finish_reason

    return "".join(parts), resp_model, total_tokens, finish_reason
