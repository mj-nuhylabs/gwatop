"""소유권 검증 헬퍼 — 라우트 여러 곳에서 동일 패턴이 반복돼서 한 군데로 모은다.

원칙: 모든 리소스는 user → semester → course → (file/schedule/todo) 의 join을 통해
현재 유저 소유인지 검증한다. 미소유일 경우 404 (존재 자체를 은닉).
"""
from __future__ import annotations

import uuid

from fastapi import HTTPException, status
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.models.course import Course
from app.models.file import File
from app.models.schedule import Schedule
from app.models.semester import Semester
from app.models.todo import Todo
from app.models.user import User


async def owned_semester(semester_id: uuid.UUID, user: User, db: AsyncSession) -> Semester:
    result = await db.execute(
        select(Semester).where(Semester.id == semester_id, Semester.user_id == user.id)
    )
    semester = result.scalar_one_or_none()
    if not semester:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Semester not found")
    return semester


async def owned_course(course_id: uuid.UUID, user: User, db: AsyncSession) -> Course:
    result = await db.execute(
        select(Course)
        .join(Semester, Course.semester_id == Semester.id)
        .where(Course.id == course_id, Semester.user_id == user.id)
    )
    course = result.scalar_one_or_none()
    if not course:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Course not found")
    return course


async def owned_schedule(
    schedule_id: uuid.UUID, user: User, db: AsyncSession
) -> tuple[Schedule, Course]:
    result = await db.execute(
        select(Schedule, Course)
        .join(Course, Schedule.course_id == Course.id)
        .join(Semester, Course.semester_id == Semester.id)
        .where(Schedule.id == schedule_id, Semester.user_id == user.id)
    )
    row = result.first()
    if not row:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Schedule not found")
    return row[0], row[1]


async def owned_todo(
    todo_id: uuid.UUID, user: User, db: AsyncSession
) -> tuple[Todo, Course]:
    result = await db.execute(
        select(Todo, Course)
        .join(Course, Todo.course_id == Course.id)
        .join(Semester, Course.semester_id == Semester.id)
        .where(Todo.id == todo_id, Semester.user_id == user.id)
    )
    row = result.first()
    if not row:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Todo not found")
    return row[0], row[1]


async def owned_file(
    file_id: uuid.UUID, user: User, db: AsyncSession
) -> tuple[File, Course | None]:
    """파일 소유권 확인.

    1) course가 연결된 일반 자료 → (file, course) 반환
    2) 강의계획서가 과목 미선택으로 업로드되어 아직 course가 없는 경우 →
       uploaded_by_user_id 로 검증하여 (file, None) 반환
    """
    # 1차: course 가 있는 자료 (대부분의 경우)
    row = (
        await db.execute(
            select(File, Course)
            .join(Course, File.course_id == Course.id)
            .join(Semester, Course.semester_id == Semester.id)
            .where(File.id == file_id, Semester.user_id == user.id)
        )
    ).first()
    if row:
        return row[0], row[1]

    # 2차: course 가 아직 없는 강의계획서 (파싱 진행 중)
    file_row = (
        await db.execute(
            select(File).where(
                File.id == file_id,
                File.uploaded_by_user_id == user.id,
            )
        )
    ).scalar_one_or_none()
    if file_row:
        return file_row, None

    raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="File not found")
