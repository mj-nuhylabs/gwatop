"""파일 자동 분류 — syllabus vs material 자동 판정 + 강의자료 과목 자동 추정.

사용자가 학기/과목/자료타입을 지정하지 않고 아무 파일이나 올렸을 때 호출된다.
extract_text_task 가 텍스트를 추출한 직후, classification_source=='auto_pending' 인 파일
대상으로 본 모듈의 detect_kind 와 guess_course_name 을 사용해 분기한다.

전략:
  1) syllabus 키워드/구조 휴리스틱 — 빠르고 99% 정확 (한국 대학 syllabus 는 정형화돼 있음).
  2) 신뢰 안 가면 gpt-4o-mini 단답 분류 호출 (저렴, 짧음).
  3) 강의자료의 과목 추정 — filename 패턴 (가장 강한 신호) → 첫 페이지 텍스트의 큰 제목 → LLM.
"""

from __future__ import annotations

import logging
import re
from dataclasses import dataclass
from typing import Literal

from openai import AsyncOpenAI

from app.core.config import settings

logger = logging.getLogger(__name__)

# OpenAI 클라이언트는 lazy 초기화 (config 로딩 순서 의존성 회피).
_client: AsyncOpenAI | None = None

def _client_lazy() -> AsyncOpenAI:
    global _client
    if _client is None:
        _client = AsyncOpenAI(api_key=settings.OPENAI_API_KEY)
    return _client


# ---------- syllabus 감지 ----------

# 강의계획서임을 강하게 시사하는 키워드/패턴 — 한국어 + 영어.
_SYLLABUS_STRONG_HITS = [
    "강의계획서", "강의 계획서", "syllabus",
    "주차별 일정", "주차별 강의", "week-by-week",
    "평가 방법", "평가비율", "평가 비율", "grading policy",
    "수업 운영", "수업운영", "course objectives",
    "office hour", "오피스아워", "office hours",
    "선수과목", "선수 과목", "prerequisite",
]
# 보조 신호 — 다수 매칭 시 syllabus 가능성 ↑
_SYLLABUS_SOFT_HITS = [
    "1주차", "2주차", "3주차",
    "week 1", "week 2", "week 3",
    "교재", "참고문헌", "textbook", "교과서",
    "출석", "지각", "결석",
    "중간고사", "기말고사", "midterm", "final exam",
    "학점", "credit", "학년도", "학기 ",
]

Kind = Literal["syllabus", "material"]


@dataclass
class KindDecision:
    kind: Kind
    confidence: float  # 0.0 ~ 1.0
    reason: str        # 디버깅용


def detect_kind_heuristic(text: str, filename: str = "") -> KindDecision | None:
    """텍스트만 보고 빠르게 판정. 확신 없으면 None 반환해서 LLM 호출 유도.

    필드명에 'syllabus' 또는 '강의계획서' 가 있으면 강한 신호.
    """
    name_lower = filename.lower()
    if "syllabus" in name_lower or "강의계획서" in name_lower or "course outline" in name_lower:
        return KindDecision("syllabus", 0.95, f"filename contains syllabus marker: {filename}")

    if not text or not text.strip():
        # 텍스트 없으면 판정 불가 — material 로 디폴트 (안전).
        return KindDecision("material", 0.40, "no text extracted; default material")

    text_lower = text[:6000].lower()  # 첫 6000자만 봐도 충분.

    strong_hits = sum(1 for kw in _SYLLABUS_STRONG_HITS if kw.lower() in text_lower)
    soft_hits = sum(1 for kw in _SYLLABUS_SOFT_HITS if kw.lower() in text_lower)

    # 강한 신호 2개 이상 → syllabus 확정.
    if strong_hits >= 2:
        return KindDecision(
            "syllabus", min(0.85 + 0.05 * strong_hits, 0.98),
            f"strong_hits={strong_hits} soft_hits={soft_hits}",
        )
    # 강한 신호 1개 + 보조 신호 3개 이상 → syllabus.
    if strong_hits >= 1 and soft_hits >= 3:
        return KindDecision(
            "syllabus", 0.80,
            f"strong_hits={strong_hits} soft_hits={soft_hits}",
        )

    # 신호가 거의 없음 (보조 ≤ 1, 강한 0) → material 확정.
    if strong_hits == 0 and soft_hits <= 1:
        return KindDecision(
            "material", 0.85,
            f"weak signals strong=0 soft={soft_hits}",
        )

    # 애매한 영역 → None 으로 LLM fallback 유도.
    return None


async def detect_kind_llm(text: str, filename: str) -> KindDecision:
    """LLM 으로 한 번 분류. ~200 input tokens, 5 output tokens — 매우 저렴/빠름."""
    sample = (text or "")[:3000]
    try:
        resp = await _client_lazy().chat.completions.create(
            model="gpt-4o-mini",
            temperature=0,
            max_tokens=10,
            messages=[
                {
                    "role": "system",
                    "content": (
                        "You classify Korean university PDF documents as either 'syllabus' "
                        "(강의계획서 — overall course plan with weekly schedule, grading, "
                        "policies) or 'material' (강의자료 — lecture slides, notes, homework). "
                        "Respond with ONE word only: 'syllabus' or 'material'."
                    ),
                },
                {
                    "role": "user",
                    "content": f"Filename: {filename}\n\nText sample:\n{sample}",
                },
            ],
        )
        ans = (resp.choices[0].message.content or "").strip().lower()
        if "syllabus" in ans:
            return KindDecision("syllabus", 0.70, f"LLM said: {ans}")
        return KindDecision("material", 0.70, f"LLM said: {ans}")
    except Exception as exc:  # noqa: BLE001
        logger.warning("auto_classifier LLM failed: %s — defaulting to material", exc)
        return KindDecision("material", 0.40, f"LLM error: {exc}")


async def detect_kind(text: str, filename: str = "") -> KindDecision:
    """공개 진입점 — 휴리스틱 우선, 애매하면 LLM."""
    h = detect_kind_heuristic(text, filename)
    if h is not None:
        return h
    return await detect_kind_llm(text, filename)


# ---------- 강의자료의 과목명 추정 ----------

# filename 에서 자주 보이는 구분자.
_NAME_SPLITTERS = re.compile(r"[\[\]_\-\(\)\s,·]+")
# 노이즈 키워드 토큰(접두). 단독 '강' 은 제거했다 — '강화학습'/'강좌' 같은 과목명
# 토큰 전체를 노이즈로 오판해 통째로 버리기 때문. '강의' 만 노이즈로 본다.
_WEEK_PATTERN = re.compile(r"(주차|week|wk|ch(?:apter)?|chap|lecture|lec|강의|과제|hw)\s*\d*", re.IGNORECASE)
# 숫자가 앞에 붙은 주차/강/장 토큰("3주차", "03주차", "5강", "2장")도 노이즈.
# _WEEK_PATTERN(접두 매칭)이 못 잡는 케이스라 별도 패턴으로 처리.
_WEEK_NUM_TOKEN = re.compile(r"^\d+\s*(?:주차?|강|장|회|차|교시)$")
_DIGITS_ONLY = re.compile(r"^\d+$")


def guess_course_name_from_filename(filename: str) -> str | None:
    """파일명에서 과목명 후보 추출. 깔끔하게 안 나오면 None.

    예: "[자료구조] 03주차 강의자료.pdf" → "자료구조"
        "운영체제_chapter5_slides.pdf"  → "운영체제"
        "DS_HW3.pdf"                   → "DS"
    """
    # 확장자 제거.
    base = filename.rsplit(".", 1)[0] if "." in filename else filename
    parts = [p for p in _NAME_SPLITTERS.split(base) if p]

    # week/chapter/lecture/hw 같은 노이즈 토큰 제거.
    cleaned: list[str] = []
    for p in parts:
        if _WEEK_PATTERN.match(p):
            continue
        if _WEEK_NUM_TOKEN.match(p):
            continue
        if _DIGITS_ONLY.match(p):
            continue
        # 너무 짧은 한 글자 토큰은 노이즈일 확률 큼 — 그러나 "DS" "OS" 같은 2글자 약자는 유지.
        if len(p) < 2:
            continue
        cleaned.append(p)

    if not cleaned:
        return None
    # 첫 두 토큰까지 결합 (한국어 단어가 분리됐을 수 있음).
    candidate = " ".join(cleaned[:2]).strip()
    return candidate if len(candidate) >= 2 else None


async def guess_course_name_llm(text: str, filename: str) -> str | None:
    """텍스트 + 파일명 기반으로 LLM 에게 과목명 한 단어 요청."""
    sample = (text or "")[:2000]
    try:
        resp = await _client_lazy().chat.completions.create(
            model="gpt-4o-mini",
            temperature=0,
            max_tokens=30,
            messages=[
                {
                    "role": "system",
                    "content": (
                        "You extract the Korean university course name from a lecture material. "
                        "Output ONLY the course name in Korean (no quotes, no extra words). "
                        "Examples: '자료구조', '운영체제', '인공지능', '선형대수'. "
                        "If unclear, respond with 'UNKNOWN'."
                    ),
                },
                {
                    "role": "user",
                    "content": f"Filename: {filename}\n\nText sample:\n{sample}",
                },
            ],
        )
        ans = (resp.choices[0].message.content or "").strip()
        if not ans or "UNKNOWN" in ans.upper() or len(ans) < 2 or len(ans) > 30:
            return None
        # 따옴표 제거.
        return ans.strip("\"'`").strip()
    except Exception as exc:  # noqa: BLE001
        logger.warning("guess_course_name_llm failed: %s", exc)
        return None


async def guess_course_name(text: str, filename: str) -> str:
    """공개 진입점 — filename 우선, 빈약하면 LLM. 최후엔 '미분류 자료'."""
    fn = guess_course_name_from_filename(filename)
    if fn and len(fn) >= 2:
        # filename 에서 깔끔하게 뽑혔으면 그대로 사용 (LLM 호출 비용 절약).
        return fn
    llm = await guess_course_name_llm(text, filename)
    if llm:
        return llm
    return "기타"
