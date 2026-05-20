"""강의계획서 텍스트 → 구조화 JSON 파서.

PyMuPDF로 추출한 강의계획서 원문 텍스트를 GPT-4o-mini로 파싱하여
과목 메타데이터 + 주차별 일정 + 시험/과제 일정을 JSON으로 반환한다.
"""

from __future__ import annotations

import json
import logging
from typing import Any

from openai import AsyncOpenAI, OpenAIError
from pydantic import ValidationError

from app.core.config import settings
from app.schemas.syllabus import (
    ParsedSyllabus,
    SyllabusParseResult,
    SyllabusParseUsage,
)

logger = logging.getLogger(__name__)


MAX_INPUT_CHARS = 18000


SYSTEM_PROMPT = """당신은 한국 대학교 강의계획서(syllabus)를 분석하는 전문 파서입니다.
입력은 PDF에서 추출된 평문 텍스트이며, 표/줄바꿈이 깨져있을 수 있습니다.
당신의 임무는 강의계획서에서 다음 정보를 구조화 JSON으로 추출하는 것입니다.

[추출 대상]
1. 과목 메타: 과목명, 담당교수, 학점, 강의실, 정규 강의 시간, 총 주차 수
2. 주차별 강의 계획 (week_number, topic, notes)
3. 시험 일정 (중간고사, 기말고사, 쪽지시험 등) — 날짜와 시간 가능한 한 정확히
4. 과제 마감 일정 (보고서, 발표, 과제 등) — 마감 날짜

[필수 규칙]
- 출력은 반드시 JSON 객체 1개. 다른 텍스트, 주석, 코드펜스 금지.
- 불확실하거나 텍스트에 명시되지 않은 값은 반드시 null. 추측 금지.
- 날짜는 ISO 8601 (YYYY-MM-DD), 시간은 HH:MM (24시간제).
- 요일 코드: MON, TUE, WED, THU, FRI, SAT, SUN.
- 학기 컨텍스트(연도/학기)는 사용자 메시지에 주어지며, 상대 표현(예: "8주차")을 절대 날짜로 변환할 때 사용한다.
- 주차별 일정에서 시험/과제 키워드(중간고사, 기말고사, 과제 제출, 보고서, 발표 등)를 발견하면 weeks 외에 exams/assignments에도 별도 항목으로 추가한다.
- 학점(credit)은 1~6 범위가 일반적. 텍스트에 없으면 null.
- 총 주차 수는 일반적으로 15 또는 16. 텍스트에 명확히 명시되지 않으면 16.
- confidence: 텍스트가 강의계획서 형식에 부합하고 핵심 필드가 잘 추출되었으면 0.8 이상, 일부 누락이면 0.5~0.7, 강의계획서가 아닌 것 같으면 0.3 이하.
- warnings: 파싱 중 모호하거나 누락된 항목을 한국어 문장으로 짧게 기록 (예: "기말고사 날짜가 명시되지 않음").

[출력 JSON 스키마]
{
  "course": {
    "name": string,
    "professor": string|null,
    "credit": integer|null,
    "location": string|null,
    "class_times": [
      {"day": "MON"|"TUE"|"WED"|"THU"|"FRI"|"SAT"|"SUN", "start_time": "HH:MM", "end_time": "HH:MM"}
    ],
    "total_weeks": integer
  },
  "weeks": [
    {"week_number": integer, "topic": string|null, "notes": string|null}
  ],
  "exams": [
    {"title": string, "exam_date": "YYYY-MM-DD"|null, "start_time": "HH:MM"|null, "end_time": "HH:MM"|null, "location": string|null, "description": string|null}
  ],
  "assignments": [
    {"title": string, "due_date": "YYYY-MM-DD"|null, "description": string|null}
  ],
  "confidence": number,
  "warnings": [string]
}
"""


def _build_user_prompt(text: str, year: int, term: str) -> str:
    term_label = {
        "1": "1학기", "2": "2학기",
        "summer": "여름 계절학기", "winter": "겨울 계절학기",
    }.get(term, term)

    return (
        f"[학기 컨텍스트]\n연도: {year}\n학기: {term_label}\n\n"
        f"[강의계획서 원문]\n{text}\n\n"
        "위 강의계획서를 시스템 프롬프트의 스키마에 맞춰 JSON으로 파싱하시오."
    )


def _truncate(text: str, limit: int = MAX_INPUT_CHARS) -> str:
    if len(text) <= limit:
        return text
    head = text[: limit - 500]
    tail = text[-500:]
    return f"{head}\n... [중략: 입력이 너무 길어 일부 생략됨] ...\n{tail}"


class SyllabusParseError(Exception):
    pass


_client: AsyncOpenAI | None = None


def _get_client() -> AsyncOpenAI:
    global _client
    if _client is None:
        if not settings.OPENAI_API_KEY:
            raise SyllabusParseError("OPENAI_API_KEY is not configured")
        _client = AsyncOpenAI(api_key=settings.OPENAI_API_KEY)
    return _client


async def parse_syllabus(
    text: str,
    year: int,
    term: str,
) -> SyllabusParseResult:
    """강의계획서 텍스트를 파싱하여 구조화 결과를 반환한다.

    Raises:
        SyllabusParseError: API 호출 실패, JSON 파싱 실패, 스키마 검증 실패.
    """
    cleaned = text.strip()
    if not cleaned:
        raise SyllabusParseError("Empty syllabus text")

    user_prompt = _build_user_prompt(_truncate(cleaned), year, term)
    client = _get_client()

    try:
        response = await client.chat.completions.create(
            model=settings.OPENAI_SYLLABUS_MODEL,
            temperature=settings.OPENAI_SYLLABUS_TEMPERATURE,
            max_tokens=settings.OPENAI_SYLLABUS_MAX_TOKENS,
            response_format={"type": "json_object"},
            messages=[
                {"role": "system", "content": SYSTEM_PROMPT},
                {"role": "user", "content": user_prompt},
            ],
        )
    except OpenAIError as exc:
        logger.exception("OpenAI syllabus parse failed")
        raise SyllabusParseError(f"OpenAI request failed: {exc}") from exc

    raw = response.choices[0].message.content or ""
    try:
        payload: Any = json.loads(raw)
    except json.JSONDecodeError as exc:
        logger.error("Syllabus parser returned non-JSON: %s", raw[:500])
        raise SyllabusParseError("Model returned invalid JSON") from exc

    try:
        syllabus = ParsedSyllabus.model_validate(payload)
    except ValidationError as exc:
        logger.error("Syllabus schema validation failed: %s", exc)
        raise SyllabusParseError(f"Schema validation failed: {exc}") from exc

    usage = SyllabusParseUsage(
        model=response.model,
        prompt_tokens=response.usage.prompt_tokens if response.usage else 0,
        completion_tokens=response.usage.completion_tokens if response.usage else 0,
        total_tokens=response.usage.total_tokens if response.usage else 0,
    )

    return SyllabusParseResult(syllabus=syllabus, usage=usage)
