"""파일 텍스트 → AI 요약 노트.

사용자가 학습 탭에서 파일을 선택하기 전에 미리 백엔드에서 요약을 만들어둔다.
저장 위치: ai_contents 테이블 (content_type='summary').
content 구조:
    {
      "headline": str,                    # 1줄 요약
      "key_points": [str, str, ...],      # 핵심 포인트 5~10개
      "sections": [                       # 섹션별 요약 (선택)
        {"title": str, "body": str}
      ],
      "study_tip": str,                   # 학습 조언
      "model": str,
      "tokens": int
    }
"""

from __future__ import annotations

import json
import logging
from typing import Any

from openai import AsyncOpenAI, OpenAIError
from pydantic import BaseModel, Field, ValidationError

from app.core.config import settings
from app.services.latex_repair import repair_latex_in_payload

logger = logging.getLogger(__name__)


MAX_INPUT_CHARS = 18000


SYSTEM_PROMPT = """당신은 한국 대학생을 위한 학습 보조 요약기입니다.
입력은 강의 자료(PDF에서 추출된 평문 텍스트)입니다.
사용자가 이 자료를 학습 시작 전에 빠르게 훑어볼 수 있도록 구조화 요약을 만듭니다.

# 규칙
1. 출력은 JSON 객체 1개만. 다른 텍스트·코드펜스 금지.
2. 한국어로 작성하되, 영문 전문 용어는 영어 그대로 유지.
3. 추측 금지 — 텍스트에 없는 내용을 만들어내지 마라.
4. 항목 수 가이드:
   - key_points: 5~10개. 한 줄 ≤ 80자.
   - sections: 자료에 명확한 절/장 구분이 있으면 채우고, 없으면 빈 배열.
   - study_tip: 시험·과제 준비에 도움될 1~2문장.
5. **수학 수식은 LaTeX 로** — 인라인 `$...$`, 블록 `$$...$$`.
   예: `$\\int_a^b f(x)dx$`. 평문 `∫[a,b]`, `^2`, `√` 금지.
6. **JSON 안 백슬래시는 반드시 두 번**. LaTeX 명령은 `\\\\int`, `\\\\text`, `\\\\times`, `\\\\frac` 처럼 항상 백슬래시 두 개로 작성하시오.
   잘못된 예: `"$\\int_a^b f(x)dx$"`  →  `\\t` 가 TAB 으로 풀려 깨짐.
   올바른 예: `"$\\\\int_a^b f(x)dx$"` → 화면에서 `\\int_a^b f(x)dx` 로 정상 표시.

# 출력 스키마
{
  "headline": "한 줄 요약 (≤ 60자)",
  "key_points": ["…", "…"],
  "sections": [{"title": "…", "body": "…"}],
  "study_tip": "…"
}
"""


class SummarizerError(Exception):
    pass


class _Section(BaseModel):
    title: str
    body: str


class _SummaryPayload(BaseModel):
    headline: str = Field(..., max_length=200)
    key_points: list[str] = Field(default_factory=list)
    sections: list[_Section] = Field(default_factory=list)
    study_tip: str = ""


_client: AsyncOpenAI | None = None


def _get_client() -> AsyncOpenAI:
    global _client
    if _client is None:
        if not settings.OPENAI_API_KEY:
            raise SummarizerError("OPENAI_API_KEY is not configured")
        _client = AsyncOpenAI(api_key=settings.OPENAI_API_KEY)
    return _client


def _truncate(text: str, limit: int = MAX_INPUT_CHARS) -> str:
    if len(text) <= limit:
        return text
    head = text[: limit - 500]
    tail = text[-500:]
    return f"{head}\n... [중략: 입력이 너무 길어 일부 생략됨] ...\n{tail}"


async def summarize_text(text: str, *, filename: str | None = None) -> dict[str, Any]:
    """파일 텍스트를 요약해 JSON 페이로드 반환. ai_contents.content 에 그대로 저장 가능."""
    cleaned = (text or "").strip()
    if not cleaned:
        raise SummarizerError("Empty text to summarize")

    user_prompt = (
        f"[파일명] {filename or '(미상)'}\n\n"
        f"[원문]\n{_truncate(cleaned)}\n\n"
        "위 자료를 시스템 프롬프트의 스키마에 맞춰 JSON으로 요약하시오."
    )

    client = _get_client()
    try:
        response = await client.chat.completions.create(
            model=settings.OPENAI_SUMMARY_MODEL,
            temperature=0.2,
            max_tokens=settings.OPENAI_SUMMARY_MAX_TOKENS,
            response_format={"type": "json_object"},
            messages=[
                {"role": "system", "content": SYSTEM_PROMPT},
                {"role": "user", "content": user_prompt},
            ],
        )
    except OpenAIError as exc:
        logger.exception("OpenAI summary call failed")
        raise SummarizerError(f"OpenAI request failed: {exc}") from exc

    raw = response.choices[0].message.content or ""
    try:
        payload = json.loads(raw)
    except json.JSONDecodeError as exc:
        logger.error("Summary returned non-JSON: %s", raw[:300])
        raise SummarizerError("Model returned invalid JSON") from exc

    # GPT 가 JSON 안 LaTeX 백슬래시를 한 번만 써서 \\t 가 TAB 으로 디코드된 케이스 복구.
    # ex) "$V = \\text{a} \\times b$" → "$V = <TAB>ext{a} <TAB>imes b$" → 원래 LaTeX 복원.
    payload = repair_latex_in_payload(payload)

    try:
        validated = _SummaryPayload.model_validate(payload)
    except ValidationError as exc:
        logger.error("Summary schema validation failed: %s", exc)
        raise SummarizerError(f"Schema validation failed: {exc}") from exc

    return {
        "headline": validated.headline,
        "key_points": validated.key_points,
        "sections": [s.model_dump() for s in validated.sections],
        "study_tip": validated.study_tip,
        "model": response.model,
        "tokens": (response.usage.total_tokens if response.usage else 0),
    }
