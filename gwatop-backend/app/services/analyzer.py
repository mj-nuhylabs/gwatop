"""파일 분석본(analysis) 생성 — 모든 학습 콘텐츠 생성기의 공유 입력.

전략:
- 업로드 직후 한 번만 GPT 호출해 원문 18,000자를 압축한 'study doc' 만들기
- ai_contents 에 content_type='analysis' 로 저장
- 퀴즈/플래시카드/마인드맵/암기/주요 주제 생성기는 이 분석본을 입력으로 사용
  → 입력 토큰 4500 → 800 으로 감소, latency 50%+ 절감, 비용도 그만큼 감소

분석본 형식 (markdown):
    # 자료 개요
    [1~2 paragraph]

    # 주요 개념
    - 개념 1: 설명
    - ...

    # 핵심 용어
    - 용어 1: 정의
    - ...

    # 구조 (섹션)
    - ...

    # 시험 출제 가능 포인트
    - ...
"""

from __future__ import annotations

import json
import logging
from typing import Any

from openai import AsyncOpenAI, OpenAIError
from pydantic import BaseModel, Field, ValidationError

from app.core.config import settings
from app.services.openai_client import get_async_openai

logger = logging.getLogger(__name__)


MAX_INPUT_CHARS = 18000


SYSTEM_PROMPT = """당신은 한국 대학생을 위한 학습 자료 분석가입니다.
주어진 자료를 '학습 콘텐츠 생성기'들이 재활용할 수 있도록 압축·구조화된 분석본으로 만듭니다.

이 분석본 한 개로:
- 퀴즈 출제자가 문제를 만들고
- 플래시카드 생성기가 단어 카드를 만들고
- 마인드맵 생성기가 트리를 만들고
- 암기 포인트/주요 개념 생성기가 항목을 추출합니다.

# 절대 규칙
1. 출력은 JSON 객체 1개. 다른 텍스트·코드펜스 금지.
2. 자료에 명시되지 않은 내용은 만들지 마라. 모르면 빈 배열.
3. 한국어로 작성하되 영문 전문 용어는 영어 그대로 유지.
4. 각 항목은 짧고 핵심만. 장문 설명 금지.

# 출력 스키마
{
  "overview": "자료의 핵심을 2~3 문장으로 요약",
  "main_concepts": [
    {"name": "개념명 (≤20자)", "summary": "1~2 문장 정의"}
  ],
  "key_terms": [
    {"term": "용어 (≤15자)", "definition": "한 줄 정의"}
  ],
  "structure": [
    "섹션 1 제목 또는 주제",
    "섹션 2 ..."
  ],
  "exam_points": [
    "시험에 나올 만한 사실/공식/날짜 (한 줄, ≤80자)"
  ]
}

# 항목 수 가이드
- main_concepts: 6~12개
- key_terms: 8~15개
- structure: 자료에 명확한 구분이 있으면 채우고, 없으면 빈 배열
- exam_points: 10~20개
"""


class AnalyzerError(Exception):
    pass


class _Concept(BaseModel):
    name: str
    summary: str = ""


class _Term(BaseModel):
    term: str
    definition: str = ""


class _AnalysisPayload(BaseModel):
    overview: str = ""
    main_concepts: list[_Concept] = Field(default_factory=list)
    key_terms: list[_Term] = Field(default_factory=list)
    structure: list[str] = Field(default_factory=list)
    exam_points: list[str] = Field(default_factory=list)


def _get_client() -> AsyncOpenAI:
    if not settings.OPENAI_API_KEY:
        raise AnalyzerError("OPENAI_API_KEY is not configured")
    return get_async_openai()


def _truncate(text: str, limit: int = MAX_INPUT_CHARS) -> str:
    if len(text) <= limit:
        return text
    return text[: limit - 500] + "\n... [중략] ...\n" + text[-500:]


async def analyze_text(text: str, *, filename: str | None = None) -> dict[str, Any]:
    """파일 텍스트 → 압축 분석본 JSON. ai_contents.content 에 그대로 저장 가능."""
    cleaned = (text or "").strip()
    if not cleaned:
        raise AnalyzerError("Empty text to analyze")

    user_prompt = (
        f"[파일명] {filename or '(미상)'}\n\n"
        f"[원문]\n{_truncate(cleaned)}\n\n"
        "위 자료를 시스템 프롬프트의 스키마에 맞춰 분석본 JSON 으로 만드시오."
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
        logger.exception("OpenAI analyze call failed")
        raise AnalyzerError(f"OpenAI request failed: {exc}") from exc

    raw = response.choices[0].message.content or ""
    try:
        payload = json.loads(raw)
    except json.JSONDecodeError as exc:
        logger.error("Analyzer returned non-JSON: %s", raw[:300])
        raise AnalyzerError("Model returned invalid JSON") from exc

    try:
        validated = _AnalysisPayload.model_validate(payload)
    except ValidationError as exc:
        logger.error("Analyzer schema validation failed: %s", exc)
        raise AnalyzerError(f"Schema validation failed: {exc}") from exc

    return {
        "overview": validated.overview,
        "main_concepts": [c.model_dump() for c in validated.main_concepts],
        "key_terms": [t.model_dump() for t in validated.key_terms],
        "structure": validated.structure,
        "exam_points": validated.exam_points,
        "model": response.model,
        "tokens": (response.usage.total_tokens if response.usage else 0),
    }


# ---------- markdown 변환 (생성기 입력용) ----------

def analysis_to_markdown(analysis: dict[str, Any]) -> str:
    """분석본 dict 를 generators 의 user prompt 에 넣기 좋은 markdown 으로 직렬화.
    원문 18,000자 대신 이 ~3,000자가 입력으로 들어간다."""
    parts: list[str] = []

    overview = (analysis or {}).get("overview") or ""
    if overview.strip():
        parts.append("# 자료 개요\n" + overview.strip())

    concepts = (analysis or {}).get("main_concepts") or []
    if concepts:
        lines = []
        for c in concepts:
            if not isinstance(c, dict):
                continue
            name = (c.get("name") or "").strip()
            summary = (c.get("summary") or "").strip()
            if name:
                lines.append(f"- **{name}**: {summary}" if summary else f"- **{name}**")
        if lines:
            parts.append("# 주요 개념\n" + "\n".join(lines))

    terms = (analysis or {}).get("key_terms") or []
    if terms:
        lines = []
        for t in terms:
            if not isinstance(t, dict):
                continue
            term = (t.get("term") or "").strip()
            definition = (t.get("definition") or "").strip()
            if term:
                lines.append(f"- **{term}**: {definition}" if definition else f"- **{term}**")
        if lines:
            parts.append("# 핵심 용어\n" + "\n".join(lines))

    structure = (analysis or {}).get("structure") or []
    if structure:
        lines = [f"- {s}" for s in structure if isinstance(s, str) and s.strip()]
        if lines:
            parts.append("# 구조\n" + "\n".join(lines))

    exam_points = (analysis or {}).get("exam_points") or []
    if exam_points:
        lines = [f"- {p}" for p in exam_points if isinstance(p, str) and p.strip()]
        if lines:
            parts.append("# 시험 출제 가능 포인트\n" + "\n".join(lines))

    return "\n\n".join(parts)
