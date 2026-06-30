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

import contextvars
import json
import logging
from typing import Any, Callable

from openai import AsyncOpenAI, OpenAIError
from pydantic import BaseModel, Field, ValidationError, field_validator, model_validator

from app.core.config import settings
from app.services.analyzer import analysis_to_markdown
from app.services.openai_client import get_async_openai
from app.services.latex_repair import repair_latex_in_payload

logger = logging.getLogger(__name__)


MAX_INPUT_CHARS = 20000


# ---------- 공통 클라이언트 ----------

class ContentGeneratorError(Exception):
    pass


def _get_client() -> AsyncOpenAI:
    if not settings.OPENAI_API_KEY:
        raise ContentGeneratorError("OPENAI_API_KEY is not configured")
    return get_async_openai()


# SSE 스트리밍 생성용 콜백. 같은 task 안에서 set 하면 _generate_json 이 토큰 델타를 흘려보낸다.
# 미설정(기본 None)이면 기존 비스트리밍 경로 그대로 — Celery 워커/기존 호출엔 영향 없음.
_stream_cb_var: contextvars.ContextVar[Callable[[str], None] | None] = (
    contextvars.ContextVar("content_gen_stream_cb", default=None)
)


def set_generation_stream_callback(cb: Callable[[str], None] | None) -> None:
    """현재 async task 컨텍스트에서 생성 토큰 델타를 받을 콜백 등록(SSE 엔드포인트 전용)."""
    _stream_cb_var.set(cb)


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


def _tag_pages(text: str) -> tuple[str, bool]:
    """form-feed(\\f)로 페이지를 나눠 각 페이지 앞에 [p.N] 마커를 붙인다.

    신규 추출 데이터는 페이지를 \\f 로 구분한다(slice_text_by_pages 전제와 동일).
    \\f 가 없으면 마커 없이 원문 그대로 반환하고 has_pages=False — 이 경우 프롬프트
    규칙상 모델은 pages 를 비운다(페이지 환각 방지).

    'all' scope 에선 \\f 가 보존돼 [p.N] = 실제 PDF 페이지번호. 범위 슬라이스는
    slice_text_by_pages 가 \\f 를 합쳐 마커가 없어지므로 pages 가 비워진다.
    """
    if "\f" not in (text or ""):
        return text or "", False
    out: list[str] = []
    n = 0
    for p in text.split("\f"):
        s = p.strip()
        if not s:
            continue
        n += 1
        out.append(f"[p.{n}]\n{s}")
    if n == 0:
        return text, False
    return "\n\n".join(out), True


def _build_paged_input(text: str, analysis: dict | None) -> str:
    """memorize/topics 전용 입력 — 페이지 마커를 주입해 페이지 인용을 가능케 한다.

    인용 가능한 본문은 페이지 태깅된 원문이다. 분석본이 있으면 참고용으로 앞에 덧붙인다
    (분석본엔 페이지 정보가 없으므로 인용 소스로는 쓰지 않는다).
    """
    paged, has_pages = _tag_pages(text or "")
    paged = _truncate(paged, MAX_INPUT_CHARS)
    if analysis:
        md = analysis_to_markdown(analysis)
        if md.strip():
            label = "본문 (페이지 표시 [p.N])" if has_pages else "본문"
            return f"# 분석 요약 (참고용)\n{md.strip()[:2500]}\n\n# {label}\n{paged}"
    return paged


async def _generate_json(
    *, system: str, user: str, max_tokens: int, temperature: float = 0.3,
) -> tuple[dict[str, Any], str, int]:
    """공통 GPT JSON 호출. (payload, model, total_tokens) 반환.

    truncation 감지: finish_reason='length' 면 max_tokens 한도 초과로 JSON 잘림.
    이 경우 명확한 에러를 던져 사용자에게 안내한다 (단순 'invalid JSON' 보다 진단 쉬움).
    """
    client = _get_client()
    messages = [
        {"role": "system", "content": system},
        {"role": "user", "content": user},
    ]
    stream_cb = _stream_cb_var.get()

    if stream_cb is not None:
        # SSE 경로 — 토큰을 흘려보내며 누적. finish_reason/usage 는 마지막 청크에서.
        try:
            stream = await client.chat.completions.create(
                model=settings.OPENAI_SUMMARY_MODEL,
                temperature=temperature,
                max_tokens=max_tokens,
                response_format={"type": "json_object"},
                messages=messages,
                stream=True,
                stream_options={"include_usage": True},
            )
            parts: list[str] = []
            finish_reason = None
            model_name = settings.OPENAI_SUMMARY_MODEL
            total_tokens = 0
            async for chunk in stream:
                if getattr(chunk, "usage", None):
                    total_tokens = chunk.usage.total_tokens
                if getattr(chunk, "model", None):
                    model_name = chunk.model
                if not chunk.choices:
                    continue
                ch = chunk.choices[0]
                if ch.finish_reason:
                    finish_reason = ch.finish_reason
                delta = (ch.delta.content or "") if ch.delta else ""
                if delta:
                    parts.append(delta)
                    try:
                        stream_cb(delta)
                    except Exception:
                        pass  # 콜백 오류가 생성을 깨면 안 됨
            raw = "".join(parts)
        except OpenAIError as exc:
            logger.exception("OpenAI streaming generation failed")
            raise ContentGeneratorError(f"OpenAI request failed: {exc}") from exc
    else:
        try:
            response = await client.chat.completions.create(
                model=settings.OPENAI_SUMMARY_MODEL,
                temperature=temperature,
                max_tokens=max_tokens,
                response_format={"type": "json_object"},
                messages=messages,
            )
        except OpenAIError as exc:
            logger.exception("OpenAI generation failed")
            raise ContentGeneratorError(f"OpenAI request failed: {exc}") from exc

        choice = response.choices[0]
        raw = choice.message.content or ""
        finish_reason = getattr(choice, "finish_reason", None)
        model_name = response.model
        total_tokens = response.usage.total_tokens if response.usage else 0

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

    # GPT 가 JSON 안 LaTeX 백슬래시를 한 번만 써서 \\t 가 TAB 으로 디코드된 케이스 복구.
    # 퀴즈/플래시카드/마인드맵/암기/주요 주제 모두 수식을 포함할 수 있어 공통 적용.
    payload = repair_latex_in_payload(payload)

    return (payload, model_name, total_tokens)


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
7. 문제 수: 객관식 4~5개 + 주관식 1~2개 (합 5~7개). 출력 짧게 유지.
8. **수학 수식·기호는 반드시 LaTeX 로 작성하고 `$...$` 안에 넣어야 한다**.
   - 모든 필드 (`question`, `choices`, `answer`, `explanation`) 에 동일 적용.
   - 변수·수식 한 글자라도 들어가면 그 부분은 `$...$` 로 감싼다.
     - 잘못: `"V = \\\\pi r^2 h"` (delimiter 없음 → 앱에서 raw `\\pi` 그대로 보임)
     - 옳음: `"$V = \\\\pi r^2 h$"`
     - 잘못: `"choices": ["dy", "dx", "π", "√"]` (그리스/유니코드 직접 사용)
     - 옳음: `"choices": ["$dy$", "$dx$", "$\\\\pi$", "$\\\\sqrt{\\\\,}$"]`
   - 적분/시그마/분수/제곱근/지수/하첨자 모두 LaTeX 명령으로. `∫[a,b]`, `√(...)`, 유니코드 `π` 직접 사용 금지.
   - ⚠️ **JSON 안 백슬래시는 반드시 두 번 (`\\\\`)**. `\\\\int`, `\\\\pi`, `\\\\frac`, `\\\\sqrt` 처럼 항상 백슬래시 두 개.
     잘못된 예: `"$\\int_a^b f(x)dx$"` → `\\t` 가 TAB 으로 풀려 깨짐.
     올바른 예: `"$\\\\int_a^b f(x)dx$"` → 화면에서 `\\int_a^b f(x)dx` 로 정상 표시.
   - `\\\\uXXXX` 같은 Unicode escape 직접 사용 금지 — 반드시 LaTeX 명령 (`\\\\pi`, `\\\\int`) 사용.

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


# 난이도별 출력 토큰 상한 — 쉬움은 문제 수·해설을 줄여 출력을 확 줄여 가장 빠르게.
_QUIZ_MAX_TOKENS = {"easy": 1400, "medium": 2400, "hard": 3500}

# 난이도별 출제 지침 — user_prompt 에 주입해 시스템 프롬프트의 기본 개수/해설 길이를 덮어쓴다.
_QUIZ_DIFFICULTY_BLOCK = {
    "easy": (
        "\n# 난이도: 쉬움 (속도 우선)\n"
        "- 문제 수를 적게: 객관식 4개 + 주관식 0~1개 (합 4~5개).\n"
        "- 자료에 그대로 나온 정의·사실을 묻는 기초 회상 수준.\n"
        "- 해설(explanation)은 1줄로 짧게.\n"
    ),
    "medium": (
        "\n# 난이도: 보통\n"
        "- 객관식 4~5개 + 주관식 1~2개 (합 5~7개).\n"
        "- 개념 이해와 간단한 적용 수준.\n"
        "- 해설은 2~3문장.\n"
    ),
    "hard": (
        "\n# 난이도: 어려움\n"
        "- 객관식 5~6개 + 주관식 2~3개 (합 6~8개).\n"
        "- 여러 개념을 결합한 적용·다단계 추론 수준. 그럴듯한 함정 보기 포함.\n"
        "- 해설은 왜 정답이고 다른 보기가 왜 틀린지 충분히.\n"
    ),
}


async def generate_quiz(
    text: str, *, filename: str | None, analysis: dict | None = None,
    exclude_questions: list[str] | None = None, difficulty: str = "easy",
) -> dict[str, Any]:
    exclusion_block = ""
    if exclude_questions:
        # 프롬프트 토큰 압박을 막기 위해 10개 / 각 200자 컷.
        trimmed = [q.strip()[:200] for q in exclude_questions if q and q.strip()][:10]
        if trimmed:
            joined = "\n".join(f"{i+1}. {q}" for i, q in enumerate(trimmed))
            exclusion_block = (
                "\n# ⚠️ 절대 출제 금지 — 사용자가 이미 풀었던 문제들\n"
                "아래 문제들과는 **반드시 다른 문제** 를 만드세요. 규칙:\n"
                "1. 같은 주제(예: 와셔법 부피)라도 묻는 각도를 완전히 바꾼다.\n"
                "   - 예) '공식이 무엇인가' → '왜 그 공식을 쓰는가' / '언제 쓰는가' / '예시 계산'.\n"
                "2. 같은 문제를 단어만 바꾸거나 보기 순서만 섞은 변형은 금지.\n"
                "3. 정답 보기 (choices) 도 이전과 겹치지 않아야 한다.\n"
                "4. 가능하면 자료의 다른 섹션/개념을 우선 활용한다.\n\n"
                "## 이미 출제된 문제 (이것들과 절대 비슷하면 안 됨)\n"
                f"{joined}\n\n"
            )
    diff_block = _QUIZ_DIFFICULTY_BLOCK.get(difficulty, _QUIZ_DIFFICULTY_BLOCK["easy"])
    user_prompt = (
        f"[파일명] {filename or '(미상)'}\n\n"
        f"[자료]\n{_build_input(text, analysis)}\n\n"
        f"{diff_block}"
        f"{exclusion_block}"
        "위 자료를 바탕으로 퀴즈를 JSON으로 출제하시오."
    )
    # 중복 회피 시엔 다양성을 위해 temperature 큰 폭 인상.
    temp = 0.9 if exclude_questions else 0.4
    # 난이도별 출력 상한 — 쉬움(1400)은 문제·해설을 줄여 출력을 확 줄여 가장 빠르게.
    # 어려움(3500)은 길어진 수식·해설로 잘림(finish_reason=length) 방지 여유. (실사용 토큰만큼만 과금)
    payload, model, tokens = await _generate_json(
        system=QUIZ_SYSTEM, user=user_prompt,
        max_tokens=_QUIZ_MAX_TOKENS.get(difficulty, _QUIZ_MAX_TOKENS["easy"]),
        temperature=temp,
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
4. 카드 수: 6~10개.
5. hint 필드는 옵션 — 어려운 카드에 한해 약간의 단서.
6. **수학 수식은 LaTeX 로**. 인라인 `$...$`, 블록 `$$...$$`. 예: `$\\int_a^b f(x)dx$`.
   평문 적분/제곱근/지수 표기(`∫`, `√`, `^2`) 금지.
7. ⚠️ **JSON 안 백슬래시는 반드시 두 번 (`\\\\`)**. LaTeX 는 `\\\\int`, `\\\\text`, `\\\\times`, `\\\\frac`, `\\\\sqrt` 처럼 항상 백슬래시 두 개로 작성.
   잘못된 예: `"$\\int x dx$"` → `\\t` 가 TAB 으로 풀려 깨짐.
   올바른 예: `"$\\\\int x dx$"` → 화면에 `\\int x dx` 로 정상.

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
    exclude_fronts: list[str] | None = None,
) -> dict[str, Any]:
    """플래시카드 생성. exclude_fronts 가 주어지면 그 용어들을 피해서 새 카드를 만든다
    — '더 만들기' 기능에서 기존 카드와 중복되지 않는 새 카드를 얻기 위해 사용.

    모델이 완벽히 지키지는 않으므로 응답 후 한 번 더 필터링한다.
    """
    exclude_block = ""
    excluded_norm: set[str] = set()
    if exclude_fronts:
        # 너무 길어지면 프롬프트 비용이 늘어 상위 60개로 컷.
        exclude_list = exclude_fronts[:60]
        excluded_norm = {f.strip().lower() for f in exclude_list if f.strip()}
        exclude_block = (
            "\n[제외할 용어 — 아래와 같은(또는 의미가 같은) 카드는 절대 만들지 마세요]\n"
            + "\n".join(f"- {f}" for f in exclude_list)
            + "\n\n위 목록과 겹치지 않는 새로운 용어/개념으로만 카드를 작성하세요.\n"
        )

    user_prompt = (
        f"[파일명] {filename or '(미상)'}\n\n"
        f"[자료]\n{_build_input(text, analysis)}\n"
        f"{exclude_block}\n"
        "위 자료에서 플래시카드를 JSON으로 만들어주세요."
    )
    payload, model, tokens = await _generate_json(
        system=FLASHCARD_SYSTEM, user=user_prompt, max_tokens=1800,
    )
    raw = payload.get("cards", [])
    validated = []
    for c in raw:
        try:
            card = _FlashCard.model_validate(c).model_dump()
        except ValidationError:
            continue
        if excluded_norm and card["front"].strip().lower() in excluded_norm:
            continue  # 모델이 제외 지시를 어긴 경우 클라이언트단에서 한 번 더 컷.
        validated.append(card)
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

MEMORIZE_SYSTEM = """당신은 한국 대학생을 위한 시험 대비 "암기 카드" 생성기입니다.
강의자료에서 시험에 나올 핵심 사실/공식/정의/수치를 뽑아, 비슷한 주제끼리 카테고리로 묶어 정리합니다.

# 절대 규칙
1. 출력은 JSON 객체 1개만. 코드펜스·설명 문장 등 다른 텍스트 금지.
2. 자료에 실제로 명시된 내용만. 추측·창작 금지. 근거 없으면 선택 필드는 null/빈배열로 둔다.
3. 포인트 수 8~14개. 각 항목 짧고 밀도 있게(출력 잘림 방지).

# 페이지 마커
- [자료] 본문에 "[p.1]","[p.2]" 같은 마커가 페이지마다 붙어 있을 수 있다.
- 마커가 있으면 그 내용이 나온 페이지 정수를 pages 에 적는다. 예: 9~10페이지면 "pages":[9,10].
- 마커가 전혀 없으면 pages 는 빈 배열 []. 페이지를 추측·날조하지 마라.

# 필드 (각 포인트)
- category(필수): 그룹명. 예 "단순조화운동의 정의","수학 공식 및 법칙","감쇠 진동". 같은 자료에서 3~6종류로 통일.
- text(필수): 반드시 외울 핵심 1개를 한 줄(≤90자). 공식이면 공식을 LaTeX로. 예 "복원력: $F=-kx$".
- importance(필수): 1~5 정수. 공식/정의/핵심수치는 보통 4~5.
- tip(선택): 외우는 요령 한 줄. 없으면 null.
- example(선택): 시험 출제 유형 한 줄. 없으면 null.
- pages(선택): 위 규칙대로 정수 배열. 없으면 [].

# 수식 표기
- 수학 기호/변수/공식은 LaTeX 인라인 "$...$"로. 평문/유니코드(x^2,√,π,ω,φ) 금지: $x^2$,$\\\\sqrt{x}$,$\\\\pi$,$\\\\omega$,$\\\\varphi$.
- ⚠️ JSON 안 백슬래시는 반드시 두 번: $\\\\frac{a}{b}$,$\\\\sqrt{k/m}$,$\\\\omega=\\\\sqrt{k/m}$.
- 한국어 단어는 절대 "$...$" 안에 넣지 마라. 수식 기호만 감싼다. $ 는 수식 구분자로만 쓰고, 수식 안에서 $ 나 \\\\$ 나 \\\\text{한국어} 를 쓰지 마라.

# 출력 스키마 (키 이름 그대로)
{"points":[{"category":"수학 공식 및 법칙","text":"변위: $x(t)=x_m\\\\cos(\\\\omega t+\\\\varphi)$","importance":5,"pages":[9,10],"tip":"코사인을 미분하면 $\\\\omega$ 가 곱해진다","example":"$t=0$ 초기조건으로 위상상수 구하기"}]}
모든 포인트에 category,text,importance,pages,tip,example 키를 모두 포함하라(근거 없으면 null 또는 []).
"""


class _MemPoint(BaseModel):
    # 기존 필수 필드 (하위호환: iOS/웹 구버전이 비-옵셔널로 읽음)
    category: str = ""
    text: str
    importance: int = Field(3, ge=1, le=5)
    # 신규 선택 필드 (전부 기본값 → 누락해도 검증 통과, iOS Decodable 은 미지 키 무시)
    pages: list[int] = Field(default_factory=list)
    tip: str | None = None
    example: str | None = None

    @field_validator("pages", mode="before")
    @classmethod
    def _coerce_pages(cls, v):
        if v is None:
            return []
        if isinstance(v, (int, str)):
            v = [v]
        if not isinstance(v, list):
            return []
        out: list[int] = []
        for x in v:
            if isinstance(x, bool):
                continue
            if isinstance(x, int):
                out.append(x)
            elif isinstance(x, str):
                digits = "".join(ch for ch in x if ch.isdigit())
                if digits:
                    out.append(int(digits))
        return sorted({p for p in out if 1 <= p <= 999})

    @field_validator("tip", "example", mode="before")
    @classmethod
    def _blank_to_none(cls, v):
        if isinstance(v, str) and not v.strip():
            return None
        return v


async def generate_memorize(
    text: str, *, filename: str | None, analysis: dict | None = None,
) -> dict[str, Any]:
    user_prompt = (
        f"[파일명] {filename or '(미상)'}\n\n"
        f"[자료]\n{_build_paged_input(text, analysis)}\n\n"
        "위 자료에서 시험에 나올 만한 암기 포인트를 JSON으로 정리하시오."
    )
    payload, model, tokens = await _generate_json(
        system=MEMORIZE_SYSTEM, user=user_prompt, max_tokens=2400, temperature=0.2,
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

TOPICS_SYSTEM = """당신은 한국 대학생을 위한 강의자료 "핵심 개념" 정리자입니다.
주요 개념을 정의·쉬운설명·특징·핵심원리·관계식·예시·학습팁과 함께 정리합니다.

# 절대 규칙
1. 출력은 JSON 객체 1개만.
2. 자료에 등장한 개념만. 추측·창작 금지. 근거 없으면 선택 필드는 null/빈배열.
3. 개념 수 6~10개. 각 필드 간결히(출력 잘림 방지).

# 페이지 마커
- [자료]에 "[p.N]" 마커가 있으면 그 개념이 나온 페이지 정수를 pages 에. 없으면 [].

# 필드 (각 개념)
- title(필수): 개념명 ≤30자. 원어 병기 가능.
- body(필수, 절대 비우지 말 것): 2~3문장 요약(정의+쉬운설명의 알맹이). 구버전 화면은 body 만 보여주므로 반드시 의미있게 채운다.
- definition(선택): 한 문장 정의. 없으면 null.
- explanation(선택): 쉬운 비유 1~2문장. 없으면 null.
- features(선택): 특징 짧은 문자열 배열(0~4). 페이지는 문장에 쓰지 말고 pages 필드에만.
- principle(선택): 핵심 원리 1~2문장. 없으면 null.
- relations(선택): 자료에 나온 "실제 수학 공식"만 LaTeX 문자열 배열(0~4)로. 공식이 없으면 반드시 []. 개념적 화살표(A→B)나 한국어 문장을 수식으로 만들지 마라.
- examples(필수, 배열): 자료의 구체 예시. 없으면 [].
- tip(선택): 학습 요령 한 줄. 없으면 null.
- pages(선택): 정수 배열. 없으면 [].

# 수식 표기
- LaTeX 인라인 "$...$". 평문/유니코드 금지. ⚠️ JSON 안 백슬래시 두 번: $\\\\frac{d}{dx}$,$\\\\sqrt{\\\\frac{k}{m}}$,$\\\\omega$.
- 한국어 단어는 절대 "$...$" 안에 넣지 마라. $ 는 수식 구분자로만. 수식 안에서 $ 나 \\\\$ 나 \\\\text{한국어} 금지.

# 출력 스키마 (키 이름 그대로)
{"topics":[{"title":"단순 조화 운동 (SHM)","body":"복원력이 변위에 비례·반대인 주기운동. 변위는 $x(t)=x_m\\\\cos(\\\\omega t+\\\\varphi)$.","definition":"복원력이 변위 크기에 비례하고 방향이 반대인 주기 운동","explanation":"그네를 살짝 밀면 앞뒤로 반복하는 것과 같다","features":["sine/cosine 으로 표현","가속도 $a=-\\\\omega^2 x$"],"principle":"뉴턴 2법칙+복원력 → $m\\\\frac{d^2x}{dt^2}=-kx$","relations":["$T=\\\\frac{1}{f}$","$\\\\omega=\\\\sqrt{\\\\frac{k}{m}}$"],"examples":["용수철 진자","기타 줄"],"tip":"$k,m$ 주어지면 $\\\\omega=\\\\sqrt{\\\\frac{k}{m}}$ 로 계산","pages":[3,9]}]}
모든 topic 에 title,body,definition,explanation,features,principle,relations,examples,tip,pages 키를 포함(근거 없으면 null/[]). body 는 절대 비우지 마라.
"""


class _Topic(BaseModel):
    # 기존 필수 필드 (하위호환: iOS/웹 구버전이 body·examples 에 의존)
    title: str
    body: str = ""  # 비면 _ensure_body 가 채움
    examples: list[str] = Field(default_factory=list)
    # 신규 선택 필드
    definition: str | None = None
    explanation: str | None = None
    features: list[str] = Field(default_factory=list)
    principle: str | None = None
    relations: list[str] = Field(default_factory=list)
    tip: str | None = None
    pages: list[int] = Field(default_factory=list)

    @field_validator("examples", "features", "relations", mode="before")
    @classmethod
    def _coerce_str_list(cls, v):
        if v is None:
            return []
        if isinstance(v, str):
            v = [v]
        if not isinstance(v, list):
            return []
        return [str(x).strip() for x in v if x is not None and str(x).strip()]

    @field_validator("pages", mode="before")
    @classmethod
    def _coerce_pages_t(cls, v):
        if v is None:
            return []
        if isinstance(v, (int, str)):
            v = [v]
        if not isinstance(v, list):
            return []
        out: list[int] = []
        for x in v:
            if isinstance(x, bool):
                continue
            if isinstance(x, int):
                out.append(x)
            elif isinstance(x, str):
                digits = "".join(ch for ch in x if ch.isdigit())
                if digits:
                    out.append(int(digits))
        return sorted({p for p in out if 1 <= p <= 999})

    @field_validator("definition", "explanation", "principle", "tip", mode="before")
    @classmethod
    def _blank_to_none_t(cls, v):
        if isinstance(v, str) and not v.strip():
            return None
        return v

    @model_validator(mode="after")
    def _ensure_body(self):
        # 구버전 렌더러(iOS GwaTopTopic.body / 웹 t.body)는 body 만 보므로 절대 비지 않게 보강.
        if not (self.body or "").strip():
            fallback = " ".join(
                s for s in (self.definition, self.explanation) if s and s.strip()
            ).strip()
            if not fallback and self.features:
                fallback = " ".join(self.features[:2])
            object.__setattr__(self, "body", fallback or self.title)
        return self


async def generate_topics(
    text: str, *, filename: str | None, analysis: dict | None = None,
) -> dict[str, Any]:
    user_prompt = (
        f"[파일명] {filename or '(미상)'}\n\n"
        f"[자료]\n{_build_paged_input(text, analysis)}\n\n"
        "위 자료의 주요 개념을 JSON으로 정리하시오."
    )
    payload, model, tokens = await _generate_json(
        system=TOPICS_SYSTEM, user=user_prompt, max_tokens=3000, temperature=0.2,
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
    exclude_questions: list[str] | None = None,
    difficulty: str = "easy",
) -> dict[str, Any]:
    fn = GENERATOR_REGISTRY.get(content_type)
    if fn is None:
        raise ContentGeneratorError(f"Unknown content_type: {content_type}")
    # exclude_questions / difficulty 는 현재 quiz 만 사용. 다른 generator 시그니처를
    # 건드리지 않기 위해 content_type 별로 분기한다.
    if content_type == "quiz":
        return await fn(text, filename=filename, analysis=analysis,
                        exclude_questions=exclude_questions, difficulty=difficulty)
    return await fn(text, filename=filename, analysis=analysis)


# ---------- 페이지 범위 슬라이싱 ----------

def slice_text_by_pages(extracted_text: str, page_range: str | None) -> str:
    """`extract_text_from_pdf_bytes` 가 페이지를 '\\n\\n' 으로 join 했다는 전제.
    완벽하지 않은 휴리스틱이지만 운영 데이터에는 충분.

    page_range 예: "1-3", "5", "2-2". None 이면 전체.
    """
    if not page_range or not page_range.strip():
        return extracted_text

    # 신규 추출 데이터는 form-feed 페이지 구분자를 사용한다. 기존 데이터는 하위호환으로
    # 예전 휴리스틱을 유지한다.
    pages = (
        [p.strip() for p in extracted_text.split("\f")]
        if "\f" in extracted_text
        else extracted_text.split("\n\n")
    )
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
