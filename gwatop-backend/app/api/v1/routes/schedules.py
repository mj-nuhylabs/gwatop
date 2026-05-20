from datetime import datetime

from fastapi import APIRouter, Depends, Query
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.api.v1.dependencies import get_current_user
from app.core.database import get_db
from app.models.course import Course
from app.models.schedule import Schedule
from app.models.semester import Semester
from app.models.user import User
from app.schemas.schedule import ScheduleResponse

router = APIRouter(tags=["Schedules"])


@router.get("/schedules", response_model=list[ScheduleResponse])
async def list_schedules(
    start: datetime | None = Query(None, description="ISO datetime, inclusive"),
    end: datetime | None = Query(None, description="ISO datetime, exclusive"),
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
