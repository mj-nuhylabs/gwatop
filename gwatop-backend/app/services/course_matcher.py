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

    # 같은 학기 안의 모든 course 중 이름이 정규화 일치하는 것 찾기
    existing = (
        await db.execute(
            select(Course).where(Course.semester_id == semester.id)
        )
    ).scalars().all()

    target_norm = _normalize(course_name)
    for c in existing:
        if _normalize(c.name) == target_norm:
            # 담당교수가 비어 있고 파싱 결과엔 있으면 채워주기 (보조 정보)
            if professor and not c.professor:
                c.professor = professor
            logger.info(
                "[COURSE_MATCH] matched name=%r → course_id=%s (semester=%s)",
                course_name, c.id, semester.id,
            )
            return c, semester, False

    # 새 생성
    color = _pick_color((c.color for c in existing))
    course = Course(
        semester_id=semester.id,
        name=course_name.strip(),
        professor=professor,
        color=color,
    )
    db.add(course)
    await db.flush()
    logger.info(
        "[COURSE_MATCH] created name=%r → course_id=%s (semester=%s, color=%s)",
        course_name, course.id, semester.id, color,
    )
    return course, semester, True
