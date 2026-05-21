import uuid
from datetime import datetime

from fastapi import APIRouter, Depends, HTTPException, Query, status
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.api.v1.dependencies import get_current_user
from app.api.v1.routes.todos import replace_auto_todos_for_schedule
from app.core.database import get_db
from app.models.course import Course
from app.models.schedule import Schedule
from app.models.semester import Semester
from app.models.user import User
from app.schemas.schedule import (
    CalendarDaySummary,
    CalendarSummaryResponse,
    ScheduleCreate,
    ScheduleResponse,
    ScheduleUpdate,
)

router = APIRouter(tags=["Schedules"])


async def _owned_course(course_id: uuid.UUID, user: User, db: AsyncSession) -> Course:
    """주어진 course가 현재 유저 소유인지 확인."""
    result = await db.execute(
        select(Course)
        .join(Semester, Course.semester_id == Semester.id)
        .where(Course.id == course_id, Semester.user_id == user.id)
    )
    course = result.scalar_one_or_none()
    if not course:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Course not found")
    return course


async def _owned_schedule(schedule_id: uuid.UUID, user: User, db: AsyncSession) -> tuple[Schedule, Course]:
    """schedule이 현재 유저 소유인지 (course → semester → user) 확인."""
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


def _to_response(schedule: Schedule, course: Course) -> ScheduleResponse:
    return ScheduleResponse(
        id=schedule.id,
        course_id=schedule.course_id,
        course_name=course.name,
        course_color=course.color,
        title=schedule.title,
        type=schedule.type,
        due_date=schedule.due_date,
        description=schedule.description,
        is_auto=schedule.is_auto,
        created_at=schedule.created_at,
    )


@router.get("/schedules", response_model=list[ScheduleResponse])
async def list_schedules(
    start: datetime | None = Query(None, description="ISO datetime, inclusive"),
    end: datetime | None = Query(None, description="ISO datetime, exclusive"),
    course_id: uuid.UUID | None = Query(None, description="Filter by course"),
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    stmt = (
        select(Schedule, Course.name, Course.color)
        .join(Course, Schedule.course_id == Course.id)
        .join(Semester, Course.semester_id == Semester.id)
        .where(Semester.user_id == current_user.id)
        .order_by(Schedule.due_date.asc())
    )
    if start is not None:
        stmt = stmt.where(Schedule.due_date >= start)
    if end is not None:
        stmt = stmt.where(Schedule.due_date < end)
    if course_id is not None:
        stmt = stmt.where(Schedule.course_id == course_id)

    rows = (await db.execute(stmt)).all()
    return [
        ScheduleResponse(
            id=s.id,
            course_id=s.course_id,
            course_name=name,
            course_color=color,
            title=s.title,
            type=s.type,
            due_date=s.due_date,
            description=s.description,
            is_auto=s.is_auto,
            created_at=s.created_at,
        )
        for s, name, color in rows
    ]


@router.get("/schedules/calendar/summary", response_model=CalendarSummaryResponse)
async def calendar_summary(
    start: datetime = Query(..., description="ISO datetime, inclusive"),
    end: datetime = Query(..., description="ISO datetime, exclusive"),
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """월간/주간 캘린더 점 표시용. 일별 type별 count만 반환 (payload 가벼움)."""
    day = func.date(Schedule.due_date)
    stmt = (
        select(day.label("day"), Schedule.type, func.count().label("cnt"))
        .join(Course, Schedule.course_id == Course.id)
        .join(Semester, Course.semester_id == Semester.id)
        .where(
            Semester.user_id == current_user.id,
            Schedule.due_date >= start,
            Schedule.due_date < end,
        )
        .group_by(day, Schedule.type)
        .order_by(day)
    )
    rows = (await db.execute(stmt)).all()

    by_day: dict[str, dict[str, int]] = {}
    for d, t, cnt in rows:
        key = d.isoformat() if hasattr(d, "isoformat") else str(d)
        by_day.setdefault(key, {})[t] = cnt

    days = [
        CalendarDaySummary(date=k, total=sum(v.values()), by_type=v)
        for k, v in sorted(by_day.items())
    ]
    return CalendarSummaryResponse(start=start, end=end, days=days)


@router.post("/schedules", response_model=ScheduleResponse, status_code=status.HTTP_201_CREATED)
async def create_schedule(
    body: ScheduleCreate,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    course = await _owned_course(body.course_id, current_user, db)

    schedule = Schedule(
        course_id=body.course_id,
        title=body.title,
        type=body.type,
        due_date=body.due_date,
        description=body.description,
        is_auto=False,  # 수동 추가
    )
    db.add(schedule)
    await db.flush()  # schedule.id 확보 후 auto todos 생성
    await replace_auto_todos_for_schedule(db, schedule)
    await db.commit()
    await db.refresh(schedule)
    return _to_response(schedule, course)


@router.put("/schedules/{schedule_id}", response_model=ScheduleResponse)
async def update_schedule(
    schedule_id: uuid.UUID,
    body: ScheduleUpdate,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    schedule, course = await _owned_schedule(schedule_id, current_user, db)

    # course_id를 바꾸려면 새 course도 유저 소유여야 함
    if body.course_id is not None and body.course_id != schedule.course_id:
        course = await _owned_course(body.course_id, current_user, db)
        schedule.course_id = body.course_id

    for field in ("title", "type", "due_date", "description"):
        value = getattr(body, field)
        if value is not None:
            setattr(schedule, field, value)

    await db.flush()
    await replace_auto_todos_for_schedule(db, schedule)
    await db.commit()
    await db.refresh(schedule)
    return _to_response(schedule, course)


@router.delete("/schedules/{schedule_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_schedule(
    schedule_id: uuid.UUID,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    from app.models.todo import Todo
    from sqlalchemy import delete as sa_delete

    schedule, _ = await _owned_schedule(schedule_id, current_user, db)
    # auto todos는 함께 삭제, 수동 todos는 FK ondelete=SET NULL로 유지 (link만 끊김)
    await db.execute(
        sa_delete(Todo).where(
            Todo.schedule_id == schedule.id,
            Todo.is_auto.is_(True),
        )
    )
    await db.delete(schedule)
    await db.commit()
