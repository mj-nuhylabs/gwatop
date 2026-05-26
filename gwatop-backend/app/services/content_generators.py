"""학습 자료로부터 AI 학습 콘텐츠 생성 (요약 외 5종).

각 generator 는 입력으로 파일 텍스트(전체 또는 페이지 범위 슬라이스)를 받고
content_type 별로 정의된 JSON 스키마를 반환한다. 모든 결과는 ai_contents 테이블에
그대로 저장되며 향후 파인튜닝 학습 데이터로 재활용 가능.

지원 content_type:
- quiz       : 객관식 + 주관식 혼합 문제
- flashcard  : 어려운 용어/개념 카드
- mindmap    : 트리 구조 마인드맵
- memorize   : 시험에 나올 만한 암기 포인트
- topics     : 주요 개념 + 설명

페이지 범위 (`scope`) 는 store 시 메타로 함께 기록되어 같은 파일에 여러 범위의 결과가
공존 가능하다 (예: 전체 / 1-3p / 4-7p).
"""

from __future__ import annotations

import json
import logging
from typing import Any

from openai import AsyncOpenAI, OpenAIError
from pydantic import BaseModel, Field, ValidationError, field_validator

from app.core.config import settings
from app.services.analyzer import analysis_to_markdown

logger = logging.getLogger(__name__)


MAX_INPUT_CHARS = 20000


# ---------- 공통 클라이언트 ----------

class ContentGeneratorError(Exception):
    pass


_client: AsyncOpenAI | None = None


def _get_client() -> AsyncOpenAI:
    global _client
    if _client is None:
        if not settings.OPENAI_API_KEY:
            raise ContentGeneratorError("OPENAI_API_KEY is not configured")
        _client = AsyncOpenAI(api_key=settings.OPENAI_API_KEY)
    return _client


def _truncate(text: str, limit: int = MAX_INPUT_CHARS) -> str:
    if len(text) <= limit:
        return text
    head = text[: limit - 500]
    tail = text[-500:]
    return f"{head}\n... [중략] ...\n{tail}"


def _build_input(text: str, analysis: dict | None) -> str:
    """generator user-prompt 의 자료 섹션을 구성.

    분석본이 있으면 그것을 우선 사용 (~3000자) + 원문 발췌 1500자 추가.
    원문 18000자 전체를 보내던 기존 방식 대비 입력 토큰 70% 이상 절감.

    분석본이 없거나 비어 있으면 원문만 사용.
    """
    if analysis:
        md = analysis_to_markdown(analysis)
        if md.strip():
            # 분석본 + 원문 일부(상위 1500자) — 분석본만으로 부족할 케이스 보강.
            snippet = (text or "").strip()[:1500]
            return f"{md}\n\n# 원문 발췌 (참고)\n{snippet}"
    return _truncate(text or "")


async def _generate_json(
    *, system: str, user: str, max_tokens: int, temperature: float = 0.3,
) -> tuple[dict[str, Any], str, int]:
    """공통 GPT JSON 호출. (payload, model, total_tokens) 반환.

    truncation 감지: finish_reason='length' 면 max_tokens 한도 초과로 JSON 잘림.
    이 경우 명확한 에러를 던져 사용자에게 안내한다 (단순 'invalid JSON' 보다 진단 쉬움).
    """
    client = _get_client()
    try:
        response = await client.chat.completions.create(
            model=settings.OPENAI_SUMMARY_MODEL,
            temperature=temperature,
            max_tokens=max_tokens,
            response_format={"type": "json_object"},
            messages=[
                {"role": "system", "content": system},
                {"role": "user", "content": user},
            ],
        )
    except OpenAIError as exc:
        logger.exception("OpenAI generation failed")
        raise ContentGeneratorError(f"OpenAI request failed: {exc}") from exc

    choice = response.choices[0]
    raw = choice.message.content or ""
    finish_reason = getattr(choice, "finish_reason", None)

    if finish_reason == "length":
        # GPT 가 max_tokens 한도 직전에 멈춰서 JSON 이 잘렸다.
        logger.warning(
            "Generator truncated by max_tokens=%d (len=%d): %s",
            max_tokens, len(raw), raw[-200:].replace("\n", " "),
        )
        raise ContentGeneratorError(
            f"응답이 너무 길어 잘렸어요 (max_tokens={max_tokens}). 페이지 범위를 좁히거나 잠시 후 다시 시도해 주세요."
        )

    try:
        payload = json.loads(raw)
    except json.JSONDecodeError as exc:
        logger.error(
            "Generator returned non-JSON (finish=%s len=%d): %s",
            finish_reason, len(raw), raw[:300],
        )
        raise ContentGeneratorError("Model returned invalid JSON") from exc

    return (
        payload,
        response.model,
        (response.usage.total_tokens if response.usage else 0),
    )


# ---------- 1) Quiz ----------

QUIZ_SYSTEM = """당신은 한국 대학생을 위한 학습 퀴즈 출제자입니다.
주어진 학습 자료에서 객관식 + 주관식이 섞인 퀴즈를 만듭니다.

규칙:
1. 출력은 JSON 객체 1개. 다른 텍스트·코드펜스 금지.
2. 객관식은 4지선다이며 정답 인덱스(0~3)를 정확히 명시.
3. 주관식은 한 줄로 답할 수 있는 짧은 답형(단답).
4. 보기에는 답이 명확히 드러나는 표현 사용. "다음 중 옳은 것"보다 구체적인 질문.
5. 모든 문제에 해설 추가. 왜 정답인지 + 다른 보기는 왜 틀렸는지 간단히.
6. 자료에 명시되지 않은 내용은 출제 금지.
7. 문제 수: 객관식 5~7개 + 주관식 2~3개 (합 7~10개).

# 출력 스키마
{
  "questions": [
    {
      "type": "multiple_choice",
      "question": "...",
      "choices": ["A", "B", "C", "D"],
      "answer_index": 0,
      "explanation": "..."
    },
    {
      "type": "short_answer",
      "question": "...",
      "answer": "...",
      "explanation": "..."
    }
  ]
}
"""


class _QuizMC(BaseModel):
    type: str = "multiple_choice"
    question: str
    choices: list[str] = Field(..., min_length=2, max_length=6)
    answer_index: int = Field(..., ge=0)
    explanation: str = ""


class _QuizShort(BaseModel):
    type: str = "short_answer"
    question: str
    answer: str
    explanation: str = ""


async def generate_quiz(
    text: str, *, filename: str | None, analysis: dict | None = None,
) -> dict[str, Any]:
    user_prompt = (
        f"[파일명] {filename or '(미상)'}\n\n"
        f"[자료]\n{_build_input(text, analysis)}\n\n"
        "위 자료를 바탕으로 퀴즈를 JSON으로 출제하시오."
    )
    payload, model, tokens = await _generate_json(
        system=QUIZ_SYSTEM, user=user_prompt, max_tokens=2200, temperature=0.4,
    )
    questions_raw = payload.get("questions", [])
    validated: list[dict[str, Any]] = []
    for q in questions_raw:
        try:
            t = q.get("type")
            if t == "multiple_choice":
                v = _QuizMC.model_validate(q)
            else:
                v = _QuizShort.model_validate({**q, "type": "short_answer"})
            validated.append(v.model_dump())
        except ValidationError:
            continue  # 잘못된 문제는 스킵
    if not validated:
        raise ContentGeneratorError("Quiz generation produced no valid questions")
    return {"questions": validated, "model": model, "tokens": tokens}


# ---------- 2) Flashcards ----------

FLASHCARD_SYSTEM = """당신은 한국 대학생을 위한 학습 플래시카드 메이커입니다.
어려운 용어·핵심 개념을 단어장 카드로 만듭니다.

규칙:
1. 출력은 JSON 객체 1개. 다른 텍스트 금지.
2. front 는 용어/질문 (≤ 30자). back 은 1~3문장 정의/설명.
3. 자료에 등장하지 않는 용어는 만들지 마라.
4. 카드 수: 8~15개.
5. hint 필드는 옵션 — 어려운 카드에 한해 약간의 단서.

# 출력 스키마
{
  "cards": [
    {"front": "...", "back": "...", "hint": "..." | null}
  ]
}
"""


class _FlashCard(BaseModel):
    front: str
    back: str
    hint: str | None = None


async def generate_flashcards(
    text: str, *, filename: str | None, analysis: dict | None = None,
) -> dict[str, Any]:
    user_prompt = (
        f"[파일명] {filename or '(미상)'}\n\n"
        f"[자료]\n{_build_input(text, analysis)}\n\n"
        "위 자료에서 플래시카드를 JSON으로 만들어주세요."
    )
    payload, model, tokens = await _generate_json(
        system=FLASHCARD_SYSTEM, user=user_prompt, max_tokens=1800,
    )
    raw = payload.get("cards", [])
    validated = []
    for c in raw:
        try:
            validated.append(_FlashCard.model_validate(c).model_dump())
        except ValidationError:
            continue
    if not validated:
        raise ContentGeneratorError("No valid flashcards")
    return {"cards": validated, "model": model, "tokens": tokens}


# ---------- 3) Mindmap ----------

MINDMAP_SYSTEM = """당신은 한국 대학생용 학습 자료를 마인드맵 트리로 변환합니다.

규칙 (응답이 잘리지 않도록 컴팩트하게):
1. 출력은 JSON 객체 1개. 다른 텍스트·코드펜스 금지.
2. root: 자료의 가장 큰 주제 한 줄 (≤ 25자).
3. 트리 깊이는 **최대 2단계** (root → child → grandchild). 4단계 이상 금지.
4. 1단계 children 수: **5~8개**. 각 child 의 grandchildren 수: **최대 4개**.
5. 각 라벨은 ≤ 20자. 긴 설명 절대 넣지 마라.
6. 모든 leaf 는 자료에 등장한 내용. 추측 금지.

# 출력 스키마 (정확히 이대로)
{
  "root": "메인 주제",
  "children": [
    {"label": "1단계 노드", "children": [{"label": "leaf", "children": []}]}
  ]
}
"""


class _MindmapNode(BaseModel):
    label: str
    children: list["_MindmapNode"] = Field(default_factory=list)

    @field_validator("children", mode="before")
    @classmethod
    def _coerce_children(cls, v):
        """GPT 가 가끔 leaf 를 dict 대신 문자열로 넣음. 자동 변환해서 받아준다.
        예: ["A", "B"] → [{"label": "A", "children": []}, {"label": "B", "children": []}]
        """
        if v is None:
            return []
        if not isinstance(v, list):
            return []
        coerced = []
        for item in v:
            if isinstance(item, str):
                coerced.append({"label": item, "children": []})
            elif isinstance(item, dict):
                # label 이 없으면 스킵 (잘못된 노드)
                if "label" in item:
                    coerced.append(item)
        return coerced


_MindmapNode.model_rebuild()


class _Mindmap(BaseModel):
    root: str
    children: list[_MindmapNode] = Field(default_factory=list)

    @field_validator("children", mode="before")
    @classmethod
    def _coerce_top_children(cls, v):
        return _MindmapNode._coerce_children(v)


def _coerce_mindmap_recursive(node: Any, depth: int, max_depth: int = 3) -> dict | None:
    """모든 깊이에서 문자열 leaf 를 dict 로 변환하고, max_depth 초과 자식은 잘라낸다.
    Pydantic 검증 전에 입력 자체를 정상화해서 어떤 GPT 출력이 와도 받아내도록."""
    if isinstance(node, str):
        return {"label": node[:50], "children": []}
    if not isinstance(node, dict):
        return None
    label = node.get("label") or node.get("name") or ""
    if not isinstance(label, str) or not label.strip():
        return None
    children_raw = node.get("children", [])
    if not isinstance(children_raw, list):
        children_raw = []
    coerced_children: list[dict] = []
    if depth < max_depth:
        for c in children_raw:
            cc = _coerce_mindmap_recursive(c, depth + 1, max_depth)
            if cc is not None:
                coerced_children.append(cc)
    return {"label": label[:50], "children": coerced_children}


async def generate_mindmap(
    text: str, *, filename: str | None, analysis: dict | None = None,
) -> dict[str, Any]:
    user_prompt = (
        f"[파일명] {filename or '(미상)'}\n\n"
        f"[자료]\n{_build_input(text, analysis)}\n\n"
        "위 자료를 마인드맵 트리 JSON으로 변환하시오."
    )
    payload, model, tokens = await _generate_json(
        system=MINDMAP_SYSTEM, user=user_prompt, max_tokens=1500,
    )

    # 1단계: 입력을 정상화 (문자열 leaf → dict, 깊이 제한, 라벨 길이 제한).
    root = payload.get("root", "") if isinstance(payload, dict) else ""
    if not isinstance(root, str) or not root.strip():
        raise ContentGeneratorError("Mindmap missing root")
    raw_children = payload.get("children", []) if isinstance(payload, dict) else []
    if not isinstance(raw_children, list):
        raw_children = []
    coerced_children = []
    for c in raw_children:
        cc = _coerce_mindmap_recursive(c, depth=1, max_depth=3)
        if cc is not None:
            coerced_children.append(cc)
    normalized = {"root": root[:50], "children": coerced_children}

    # 2단계: 마지막 Pydantic 검증 (이제 거의 항상 성공).
    try:
        validated = _Mindmap.model_validate(normalized)
    except ValidationError as exc:
        raise ContentGeneratorError(f"Mindmap schema invalid: {exc}") from exc
    return {**validated.model_dump(), "model": model, "tokens": tokens}


# ---------- 4) Memorize (암기 포인트) ----------

MEMORIZE_SYSTEM = """당신은 한국 대학생을 위한 시험 대비 암기 포인트 추출기입니다.
시험에 나올 가능성이 높은 핵심 내용을 한 줄 요약으로 정리합니다.

규칙:
1. 출력은 JSON 객체 1개.
2. 각 포인트는 한 줄(≤ 80자)로 외울 수 있는 사실/공식/정의/날짜.
3. category 는 자료 안에서 비슷한 주제끼리 묶을 때 사용 (예: "기본 개념", "공식", "사례").
4. importance 는 1~5 (5가 가장 시험에 자주 나옴).
5. 자료에 명시된 내용만. 추측 금지.
6. 포인트 수: 10~20개.

# 출력 스키마
{
  "points": [
    {"category": "...", "text": "...", "importance": 4}
  ]
}
"""


class _MemPoint(BaseModel):
    category: str = ""
    text: str
    importance: int = Field(3, ge=1, le=5)


async def generate_memorize(
    text: str, *, filename: str | None, analysis: dict | None = None,
) -> dict[str, Any]:
    user_prompt = (
        f"[파일명] {filename or '(미상)'}\n\n"
        f"[자료]\n{_build_input(text, analysis)}\n\n"
        "위 자료에서 시험에 나올 만한 암기 포인트를 JSON으로 정리하시오."
    )
    payload, model, tokens = await _generate_json(
        system=MEMORIZE_SYSTEM, user=user_prompt, max_tokens=1800,
    )
    raw = payload.get("points", [])
    validated = []
    for p in raw:
        try:
            validated.append(_MemPoint.model_validate(p).model_dump())
        except ValidationError:
            continue
    if not validated:
        raise ContentGeneratorError("No valid memorize points")
    return {"points": validated, "model": model, "tokens": tokens}


# ---------- 5) Topics (주요 개념) ----------

TOPICS_SYSTEM = """당신은 한국 대학생을 위한 학습 자료 핵심 개념 정리자입니다.

규칙:
1. 출력은 JSON 객체 1개.
2. 각 개념은 title + body 형태. title 은 ≤25자, body 는 2~4문장.
3. body 는 학생이 그 개념을 처음 접하는 사람에게도 이해되도록 설명.
4. 자료에 등장한 핵심 개념만. 6~12개.
5. examples 는 옵션 — 자료에 예시가 있을 때만.

# 출력 스키마
{
  "topics": [
    {"title": "...", "body": "...", "examples": ["..."]}
  ]
}
"""


class _Topic(BaseModel):
    title: str
    body: str
    examples: list[str] = Field(default_factory=list)


async def generate_topics(
    text: str, *, filename: str | None, analysis: dict | None = None,
) -> dict[str, Any]:
    user_prompt = (
        f"[파일명] {filename or '(미상)'}\n\n"
        f"[자료]\n{_build_input(text, analysis)}\n\n"
        "위 자료의 주요 개념을 JSON으로 정리하시오."
    )
    payload, model, tokens = await _generate_json(
        system=TOPICS_SYSTEM, user=user_prompt, max_tokens=2000,
    )
    raw = payload.get("topics", [])
    validated = []
    for t in raw:
        try:
            validated.append(_Topic.model_validate(t).model_dump())
        except ValidationError:
            continue
    if not validated:
        raise ContentGeneratorError("No valid topics")
    return {"topics": validated, "model": model, "tokens": tokens}


# ---------- 디스패처 ----------

GENERATOR_REGISTRY = {
    "quiz":       generate_quiz,
    "flashcard":  generate_flashcards,
    "mindmap":    generate_mindmap,
    "memorize":   generate_memorize,
    "topics":     generate_topics,
}


async def generate_content(
    content_type: str,
    text: str,
    *,
    filename: str | None = None,
    analysis: dict | None = None,
) -> dict[str, Any]:
    fn = GENERATOR_REGISTRY.get(content_type)
    if fn is None:
        raise ContentGeneratorError(f"Unknown content_type: {content_type}")
    return await fn(text, filename=filename, analysis=analysis)


# ---------- 페이지 범위 슬라이싱 ----------

def slice_text_by_pages(extracted_text: str, page_range: str | None) -> str:
    """`extract_text_from_pdf_bytes` 가 페이지를 '\\n\\n' 으로 join 했다는 전제.
    완벽하지 않은 휴리스틱이지만 운영 데이터에는 충분.

    page_range 예: "1-3", "5", "2-2". None 이면 전체.
    """
    if not page_range or not page_range.strip():
        return extracted_text

    # 단순 split (TODO: 더 신뢰성 있는 per-page 저장 도입)
    pages = extracted_text.split("\n\n")
    if not pages:
        return extracted_text

    try:
        if "-" in page_range:
            start_s, end_s = page_range.split("-", 1)
            start = max(1, int(start_s.strip()))
            end = max(start, int(end_s.strip()))
        else:
            start = end = max(1, int(page_range.strip()))
    except (ValueError, AttributeError):
        return extracted_text

    sliced = pages[start - 1 : end]
    return "\n\n".join(sliced) if sliced else extracted_text
