"""파싱된 강의계획서의 강의명으로 기존 course에 매칭 또는 새 course 생성.

규칙:
- 사용자의 active semester 안에서 같은 이름의 course(대소문자/공백 무시) 검색
- 매칭되면 그 course 반환
- 없으면 active semester 안에 새 course 생성 후 반환 (담당교수도 함께 기록)
- active semester가 없으면 가장 최근 학기를 폴백으로, 그것도 없으면 에러
"""
from __future__ import annotations

import json
import logging
import random
import re
from datetime import date
from typing import Iterable, Sequence

from openai import OpenAIError
from pydantic import BaseModel, ValidationError
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.config import settings
from app.core.database import kst_now_naive
from app.models.course import Course
from app.models.semester import Semester
from app.models.user import User
from app.services.openai_client import get_async_openai
from app.services.structured_llm import structured_chat_json

logger = logging.getLogger(__name__)


class _CourseMatchDecision(BaseModel):
    """LLM 디스앰비규에이션 응답 — 후보 번호(1-based) 또는 null."""

    match_id: int | None
    confidence: float
    reason: str


_MATCH_SYSTEM = """당신은 대학 학습자료를 올바른 강의계획서(과목)에 연결하는 도구입니다.
새 학습자료의 신원 정보와 기존 과목 후보 목록을 보고, 어느 과목에 속하는지 고르세요.
JSON만 출력합니다. 약한 단서뿐이면 match_id 를 null 로 하고 confidence 를 낮추세요.
과목명은 동의어가 많습니다(미적분학/미적분/Calculus/미적1). 과목명이 모호할 때는
subject_keywords 가 결정적 단서입니다(예: 적분·극한·테일러급수 → 미적분 계열).
출력: {"match_id": 후보번호 또는 null, "confidence": 0~1, "reason": "근거 한 문장"}"""


async def match_course_llm(
    course_name: str,
    professor: str | None,
    semester_name: str,
    subject_keywords: Sequence[str] | None,
    candidates: Sequence[Course],
) -> tuple[int | None, float, str]:
    """모호한 후보들 중에서 LLM 으로 1개 선택. 반환: (0-based 인덱스 또는 None, confidence, reason).

    실패/파싱오류 시 (None, 0.0, 사유) — 호출자는 규칙 결과로 폴백한다.
    """
    listing = "\n".join(
        f"[{i + 1}] {c.name} / {c.professor or '교수미상'} / {semester_name}"
        for i, c in enumerate(candidates)
    )
    kw = ", ".join(subject_keywords or []) or "(없음)"
    user = (
        f"새 학습자료 신원: 과목명: {course_name} / 교수: {professor or '미상'} / "
        f"학기: {semester_name}\n본문 주제 키워드: {kw}\n\n기존 과목 후보:\n{listing}"
    )
    try:
        raw, _m, _t, _f = await structured_chat_json(
            get_async_openai(),
            model=settings.COURSE_MATCH_MODEL,
            system=_MATCH_SYSTEM,
            user=user,
            schema_model=_CourseMatchDecision,
            schema_name="course_match",
            max_tokens=120,
            temperature=0,
        )
        d = _CourseMatchDecision.model_validate(json.loads(raw))
    except (OpenAIError, json.JSONDecodeError, ValidationError) as exc:
        logger.warning("match_course_llm 실패: %s — 규칙 결과로 폴백", exc)
        return None, 0.0, f"llm_error: {exc}"

    if d.match_id is None or not (1 <= d.match_id <= len(candidates)):
        return None, d.confidence, d.reason
    return d.match_id - 1, d.confidence, d.reason


class CourseMatchError(Exception):
    """active/최근 학기가 하나도 없어서 강의를 자동 배정할 수 없을 때."""


# 새 과목 생성 시 자동으로 부여할 색상 팔레트. iOS GwaTopCourseFormView 와 동일 톤.
_COLOR_PALETTE = [
    "#4F8EF7", "#22C55E", "#F97316", "#A855F7",
    "#EC4899", "#0EA5E9", "#EF4444", "#14B8A6",
]


def _normalize(name: str) -> str:
    return "".join(name.split()).lower()


# 과목명 fuzzy 매칭에서 흔히 나오는 "공통 단어" — 매칭 신호로 안 침. 예: "와", "및", "and".
_FILLER_TOKENS = {
    "와", "과", "및", "그리고",
    "and", "the", "of", "for",
    "강의", "수업", "이론", "실습",
}


_TOKEN_SPLIT_RE = re.compile(r"[\s,·\-_/()\[\]]+")


def _meaningful_tokens(name: str) -> list[str]:
    """공백·구분자로 분리한 뒤 의미 있는 토큰만 반환.

    "자료구조와 알고리즘" → ["자료구조", "알고리즘"]
    "Operating Systems"  → ["operating", "systems"]
    """
    raw = [t for t in _TOKEN_SPLIT_RE.split(name) if t]
    out: list[str] = []
    for t in raw:
        tl = t.lower()
        if tl in _FILLER_TOKENS:
            continue
        if len(tl) < 2:
            continue
        out.append(tl)
    return out


def _fuzzy_score(target: str, candidate: str) -> float:
    """0.0 ~ 1.0 사이 유사도. 높을수록 같은 과목 가능성 ↑.

    전략:
    - 정규화 정확 일치: 1.0
    - 추측 이름이 기존 과목 이름에 완전히 포함 (혹은 그 반대): 0.85+
    - 의미 있는 토큰들이 얼마나 겹치는지: 0~0.7
    """
    t_norm = _normalize(target)
    c_norm = _normalize(candidate)
    if not t_norm or not c_norm:
        return 0.0
    if t_norm == c_norm:
        return 1.0
    # 한쪽이 다른 쪽에 통째로 포함 — 예: "자료구조" ⊂ "자료구조와알고리즘"
    if t_norm in c_norm or c_norm in t_norm:
        # 짧은 쪽 / 긴 쪽 비율로 보정 — 너무 짧은 substring 매칭 방지.
        shorter = min(len(t_norm), len(c_norm))
        longer = max(len(t_norm), len(c_norm))
        # shorter 가 너무 짧으면 (2자 이하) 노이즈 가능성 ↑ — 점수 깎음.
        base = 0.85 + 0.10 * (shorter / longer)
        return base if shorter >= 3 else base - 0.20

    # 의미 있는 토큰 겹침으로 평가.
    t_tokens = set(_meaningful_tokens(target))
    c_tokens = set(_meaningful_tokens(candidate))
    if not t_tokens or not c_tokens:
        return 0.0
    overlap = t_tokens & c_tokens
    if not overlap:
        return 0.0
    # Jaccard 유사도.
    union = t_tokens | c_tokens
    jaccard = len(overlap) / len(union)
    return min(0.70, 0.40 + 0.45 * jaccard)


# 같은 과목으로 인정할 최소 fuzzy 점수. 이 미만이면 신뢰 안 가서 새 생성 폴백.
_FUZZY_THRESHOLD = 0.70


def _build_default_semester(user_id) -> Semester:
    """오늘(KST) 날짜로 기본 학기를 만든다. 강의계획서를 학기 미선택으로 올렸는데
    등록된 학기가 0개일 때, 사용자가 따로 학기를 만들 필요 없이 자동 생성하기 위함.

    월 기준 학기 구분 (iOS defaultSemesterName 과 동일):
      3~6월  → N-1학기   / 9~12월 → N-2학기
      7~8월  → 여름 계절학기 / 1~2월  → 겨울 계절학기
    """
    today = kst_now_naive().date()
    y, m = today.year, today.month
    if 3 <= m <= 6:
        name, start, end = f"{y}-1학기", date(y, 3, 1), date(y, 6, 30)
    elif 9 <= m <= 12:
        name, start, end = f"{y}-2학기", date(y, 9, 1), date(y, 12, 31)
    elif 7 <= m <= 8:
        name, start, end = f"{y} 여름 계절학기", date(y, 7, 1), date(y, 8, 31)
    else:  # 1~2월
        name, start, end = f"{y} 겨울 계절학기", date(y, 1, 1), date(y, 2, 28)
    return Semester(
        user_id=user_id,
        name=name,
        start_date=start,
        end_date=end,
        is_active=True,
    )


async def _pick_target_semester(db: AsyncSession, user: User) -> Semester:
    # 1) active
    active = (
        await db.execute(
            select(Semester).where(
                Semester.user_id == user.id,
                Semester.is_active.is_(True),
            )
        )
    ).scalar_one_or_none()
    if active:
        return active

    # 2) 가장 최근 시작 학기
    recent = (
        await db.execute(
            select(Semester)
            .where(Semester.user_id == user.id)
            .order_by(Semester.start_date.desc())
            .limit(1)
        )
    ).scalar_one_or_none()
    if recent:
        return recent

    # 3) 학기 0개 — 예전엔 여기서 에러를 던져 업로드가 실패했다.
    #    이제는 오늘 날짜 기준 학기를 자동 생성해서 사용자가 학기를 먼저 만들 필요가 없게 한다.
    logger.info(
        "등록 학기 0개 — 강의계획서 자동 배정 위해 기본 학기 자동 생성 user=%s", user.id
    )
    sem = _build_default_semester(user.id)
    db.add(sem)
    await db.flush()  # 이후 course 생성에 semester.id 필요 → flush 로 PK 확보
    return sem


def _pick_color(existing_colors: Iterable[str | None]) -> str:
    used = {c for c in existing_colors if c}
    unused = [c for c in _COLOR_PALETTE if c not in used]
    return random.choice(unused) if unused else random.choice(_COLOR_PALETTE)


def _attach_professor(course: Course, professor: str | None) -> None:
    if professor and not course.professor:
        course.professor = professor


async def match_or_create_course(
    db: AsyncSession,
    user: User,
    course_name: str,
    professor: str | None = None,
    subject_keywords: Sequence[str] | None = None,
) -> tuple[Course, Semester, bool]:
    """파싱된 course name으로 매칭 또는 생성. 반환: (course, semester, created).

    값싼 규칙(정규화 정확일치 → 퍼지) 우선. 1·2위가 근소차로 모호하거나 best 가
    임계값 미만인 "애매한" 경우에만 LLM 디스앰비규에이션(subject_keywords 활용)을 1회 시도.
    대부분(후보 0~1개, 명확한 1위)은 LLM 0회로 끝난다.

    Raises:
        CourseMatchError: 학기가 하나도 없을 때.
    """
    semester = await _pick_target_semester(db, user)

    # 같은 학기 안의 모든 course 후보를 한 번에 가져옴.
    existing = (
        await db.execute(
            select(Course).where(Course.semester_id == semester.id)
        )
    ).scalars().all()

    # 1) 정규화 정확 일치 — 가장 빠르고 확실. (LLM 0회)
    target_norm = _normalize(course_name)
    for c in existing:
        if _normalize(c.name) == target_norm:
            _attach_professor(c, professor)
            logger.info(
                "[COURSE_MATCH] exact name=%r → course_id=%s (semester=%s)",
                course_name, c.id, semester.id,
            )
            return c, semester, False

    # 2) Fuzzy 후보 점수화 — substring/토큰 겹침.
    scored = sorted(
        ((c, _fuzzy_score(course_name, c.name)) for c in existing),
        key=lambda x: x[1],
        reverse=True,
    )
    best = scored[0] if scored else None
    second = scored[1] if len(scored) > 1 else None
    margin = (best[1] - second[1]) if (best and second) else (best[1] if best else 0.0)

    # 2-a) 명확한 1위 — best 가 임계값 이상이고 2위와 충분히 벌어졌으면 규칙만으로 확정. (LLM 0회)
    if best is not None and best[1] >= settings.COURSE_MATCH_FUZZY_THRESHOLD \
            and margin >= settings.COURSE_MATCH_AMBIGUOUS_MARGIN:
        _attach_professor(best[0], professor)
        logger.info(
            "[COURSE_MATCH] fuzzy(clear) guess=%r ~ existing=%r score=%.2f margin=%.2f → %s",
            course_name, best[0].name, best[1], margin, best[0].id,
        )
        return best[0], semester, False

    # 3) 애매 — 후보가 있으면 LLM 디스앰비규에이션 (subject_keywords 가 결정적 단서).
    #    트리거: best 가 임계값 미만(약한 후보)이거나, 1·2위가 근소차(동의어 충돌).
    candidates = [c for c, s in scored[:5] if s > 0.0]
    if candidates and settings.COURSE_MATCH_LLM_ENABLED:
        idx, conf, reason = await match_course_llm(
            course_name, professor, semester.name, subject_keywords, candidates,
        )
        if idx is not None and conf >= 0.6:
            chosen = candidates[idx]
            _attach_professor(chosen, professor)
            logger.info(
                "[COURSE_MATCH] llm guess=%r → existing=%r conf=%.2f reason=%s → %s",
                course_name, chosen.name, conf, reason, chosen.id,
            )
            return chosen, semester, False
        logger.info(
            "[COURSE_MATCH] llm inconclusive guess=%r conf=%.2f reason=%s",
            course_name, conf, reason,
        )

    # 4) LLM 이 결론을 못 냈지만 규칙상 best 가 임계값 이상이면 그걸 채택(중복 과목 방지).
    if best is not None and best[1] >= settings.COURSE_MATCH_FUZZY_THRESHOLD:
        _attach_professor(best[0], professor)
        logger.info(
            "[COURSE_MATCH] fuzzy(fallback) guess=%r ~ existing=%r score=%.2f → %s",
            course_name, best[0].name, best[1], best[0].id,
        )
        return best[0], semester, False

    # 5) 새 생성 — 매칭 후보가 정말 없을 때만.
    color = _pick_color((c.color for c in existing))
    course = Course(
        semester_id=semester.id,
        name=course_name.strip(),
        professor=professor,
        color=color,
    )
    db.add(course)
    await db.flush()
    best_log = f"best={best[0].name!r}@{best[1]:.2f}" if best else "no_candidates"
    logger.info(
        "[COURSE_MATCH] created name=%r → course_id=%s (semester=%s, color=%s, %s)",
        course_name, course.id, semester.id, color, best_log,
    )
    return course, semester, True
