"""AI 튜터 채팅 — 파일 컨텍스트 기반 멀티턴 응답.

OpenAI Chat Completions 를 호출하되, 파일의 extracted_text 를 system 메시지에
추가 컨텍스트로 첨부한다. 모든 메시지는 tutor_messages 테이블에 저장.
"""

from __future__ import annotations

import logging
from typing import Iterable

from openai import AsyncOpenAI, OpenAIError

from app.core.config import settings

logger = logging.getLogger(__name__)


MAX_CONTEXT_CHARS = 18000
MAX_HISTORY_TURNS = 8   # user/assistant 합쳐서 최근 N개 메시지만 컨텍스트로


class TutorError(Exception):
    pass


_client: AsyncOpenAI | None = None


def _get_client() -> AsyncOpenAI:
    global _client
    if _client is None:
        if not settings.OPENAI_API_KEY:
            raise TutorError("OPENAI_API_KEY is not configured")
        _client = AsyncOpenAI(api_key=settings.OPENAI_API_KEY)
    return _client


def _build_system_prompt(file_text: str, filename: str | None) -> str:
    if len(file_text) > MAX_CONTEXT_CHARS:
        head = file_text[: MAX_CONTEXT_CHARS - 500]
        tail = file_text[-500:]
        file_text = f"{head}\n... [중략] ...\n{tail}"

    return (
        "당신은 한국 대학생을 도와주는 친절한 AI 튜터입니다.\n"
        "사용자의 학습 자료를 기반으로 질문에 답합니다.\n"
        "\n"
        "지침:\n"
        "1. 자료에 직접 명시된 내용을 우선 인용하시오.\n"
        "2. 자료에 없는 내용은 추측하지 말고 \"이 자료에는 직접 언급되지 않았어요\" 라고 알리세요.\n"
        "3. 설명은 핵심 → 부연 순서로, 어려운 용어는 풀어서.\n"
        "4. 너무 길면 잘게 끊어 보여주세요. 마크다운 헤더/리스트 활용 가능.\n"
        "5. 한국어로 답하되 전문 영어 용어는 그대로.\n"
        "\n"
        f"[학습 자료 파일명] {filename or '(미상)'}\n"
        "[자료 본문]\n"
        f"{file_text}\n"
    )


async def ask_tutor(
    *,
    file_text: str,
    filename: str | None,
    history: Iterable[tuple[str, str]],  # [(role, body), ...] 최근 메시지 (오래된 순)
    user_question: str,
) -> tuple[str, int]:
    """튜터에게 한 번 질문하고 응답을 반환. (answer_body, tokens) 튜플.

    history 는 너무 길면 자동으로 마지막 MAX_HISTORY_TURNS 개로 잘린다.
    """
    history_list = list(history)[-MAX_HISTORY_TURNS:]

    messages: list[dict[str, str]] = [
        {"role": "system", "content": _build_system_prompt(file_text, filename)}
    ]
    for role, body in history_list:
        if role not in ("user", "assistant"):
            continue
        messages.append({"role": role, "content": body})
    messages.append({"role": "user", "content": user_question})

    client = _get_client()
    try:
        response = await client.chat.completions.create(
            model=settings.OPENAI_SUMMARY_MODEL,
            temperature=0.4,
            max_tokens=900,
            messages=messages,
        )
    except OpenAIError as exc:
        logger.exception("OpenAI tutor call failed")
        raise TutorError(f"OpenAI request failed: {exc}") from exc

    answer = response.choices[0].message.content or ""
    tokens = response.usage.total_tokens if response.usage else 0
    return answer.strip(), tokens
