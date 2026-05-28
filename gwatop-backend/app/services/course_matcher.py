"""파싱된 강의계획서의 강의명으로 기존 course에 매칭 또는 새 course 생성.

규칙:
- 사용자의 active semester 안에서 같은 이름의 course(대소문자/공백 무시) 검색
- 매칭되면 그 course 반환
- 없으면 active semester 안에 새 course 생성 후 반환 (담당교수도 함께 기록)
- active semester가 없으면 가장 최근 학기를 폴백으로, 그것도 없으면 에러
"""
from __future__ import annotations

import logging
import random
import re
from typing import Iterable

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.models.course import Course
from app.models.semester import Semester
from app.models.user import User

logger = logging.getLogger(__name__)


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

    raise CourseMatchError(
        "등록된 학기가 없어 강의계획서를 자동 배정할 수 없습니다. 먼저 학기를 추가해 주세요."
    )


def _pick_color(existing_colors: Iterable[str | None]) -> str:
    used = {c for c in existing_colors if c}
    unused = [c for c in _COLOR_PALETTE if c not in used]
    return random.choice(unused) if unused else random.choice(_COLOR_PALETTE)


async def match_or_create_course(
    db: AsyncSession,
    user: User,
    course_name: str,
    professor: str | None = None,
) -> tuple[Course, Semester, bool]:
    """파싱된 course name으로 매칭 또는 생성. 반환: (course, semester, created).

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

    # 1) 정규화 정확 일치 — 가장 빠르고 확실.
    target_norm = _normalize(course_name)
    for c in existing:
        if _normalize(c.name) == target_norm:
            if professor and not c.professor:
                c.professor = professor
            logger.info(
                "[COURSE_MATCH] exact name=%r → course_id=%s (semester=%s)",
                course_name, c.id, semester.id,
            )
            return c, semester, False

    # 2) Fuzzy 매칭 — substring/토큰 겹침으로 가장 유사한 기존 과목 찾기.
    #    학생이 같은 과목을 "자료구조" / "자료구조와 알고리즘" / "DS" 처럼 다르게 적었을 때
    #    매번 새 과목 안 만들고 묶이도록.
    best: tuple[Course, float] | None = None
    for c in existing:
        score = _fuzzy_score(course_name, c.name)
        if best is None or score > best[1]:
            best = (c, score)

    if best is not None and best[1] >= _FUZZY_THRESHOLD:
        c = best[0]
        if professor and not c.professor:
            c.professor = professor
        logger.info(
            "[COURSE_MATCH] fuzzy guess=%r ~ existing=%r score=%.2f → course_id=%s",
            course_name, c.name, best[1], c.id,
        )
        return c, semester, False

    # 3) 새 생성 — 매칭 후보가 정말 없을 때만.
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
