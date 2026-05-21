"""홈 대시보드: 첫 화면에서 필요한 데이터를 한 번의 요청으로 받기.

iOS GwaTopHomeView 가 mock data 대신 이 엔드포인트를 호출한다.
내부적으로 schedules/todos를 join으로만 가져와서 N+1 없음.
"""
from datetime import datetime, timedelta

from fastapi import APIRouter, Depends
from sqlalchemy import case, func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.api.v1.dependencies import get_current_user
from app.core.database import get_db, kst_now_naive
from app.models.course import Course
from app.models.schedule import Schedule
from app.models.semester import Semester
from app.models.todo import Todo
from app.models.user import User
from app.schemas.home import HomeDashboardResponse, NextEvent, WeekSummary
from app.schemas.schedule import ScheduleResponse
from app.schemas.todo import TodoResponse

router = APIRouter(tags=["Home"])


def _start_of_today_kst() -> datetime:
    now = kst_now_naive()
    return now.replace(hour=0, minute=0, second=0, microsecond=0)


def _start_of_this_week_kst() -> datetime:
    """이번 주 월요일 0시 (KST)."""
    today = _start_of_today_kst()
    return today - timedelta(days=today.weekday())


@router.get("/home/dashboard", response_model=HomeDashboardResponse)
async def home_dashboard(
    upcoming_limit: int = 10,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    today_start = _start_of_today_kst()
    today_end = today_start + timedelta(days=1)
    week_start = _start_of_this_week_kst()
    week_end = week_start + timedelta(days=7)
    now = kst_now_naive()

    # ----- 1) 오늘의 일정 -----
    today_q = (
        select(Schedule, Course.name, Course.color)
        .join(Course, Schedule.course_id == Course.id)
        .join(Semester, Course.semester_id == Semester.id)
        .where(
            Semester.user_id == current_user.id,
            Schedule.due_date >= today_start,
            Schedule.due_date < today_end,
        )
        .order_by(Schedule.due_date.asc())
    )
    today_rows = (await db.execute(today_q)).all()
    today_schedules = [
        ScheduleResponse(
            id=s.id, course_id=s.course_id, course_name=name, course_color=color,
            title=s.title, type=s.type, due_date=s.due_date,
            description=s.description, is_auto=s.is_auto, created_at=s.created_at,
        )
        for s, name, color in today_rows
    ]

    # ----- 2) 임박한 todos (priority high→medium→low, due_date asc) -----
    priority_order = case(
        (Todo.priority == "high", 0),
        (Todo.priority == "medium", 1),
        else_=2,
    )
    upcoming_q = (
        select(Todo, Course.name, Course.color)
        .join(Course, Todo.course_id == Course.id)
        .join(Semester, Course.semester_id == Semester.id)
        .where(
            Semester.user_id == current_user.id,
            Todo.is_done.is_(False),
            Todo.due_date >= today_start,
        )
        .order_by(priority_order.asc(), Todo.due_date.asc())
        .limit(upcoming_limit)
    )
    upcoming_rows = (await db.execute(upcoming_q)).all()
    upcoming_todos = [
        TodoResponse(
            id=t.id, course_id=t.course_id, schedule_id=t.schedule_id,
            course_name=name, course_color=color,
            title=t.title, due_date=t.due_date, priority=t.priority,
            is_done=t.is_done, is_auto=t.is_auto, created_at=t.created_at,
        )
        for t, name, color in upcoming_rows
    ]

    # ----- 3) 이번 주 완료율 (월~일) -----
    week_total_q = (
        select(
            func.count().label("total"),
            func.sum(case((Todo.is_done.is_(True), 1), else_=0)).label("done"),
        )
        .join(Course, Todo.course_id == Course.id)
        .join(Semester, Course.semester_id == Semester.id)
        .where(
            Semester.user_id == current_user.id,
            Todo.due_date >= week_start,
            Todo.due_date < week_end,
        )
    )
    week_row = (await db.execute(week_total_q)).one()
    total = int(week_row.total or 0)
    done = int(week_row.done or 0)
    rate = (done / total) if total > 0 else 0.0
    this_week_summary = WeekSummary(total=total, done=done, rate=round(rate, 4))

    # ----- 4) 다음 임박 schedule (미래) -----
    next_q = (
        select(Schedule, Course.name, Course.color)
        .join(Course, Schedule.course_id == Course.id)
        .join(Semester, Course.semester_id == Semester.id)
        .where(
            Semester.user_id == current_user.id,
            Schedule.due_date >= now,
        )
        .order_by(Schedule.due_date.asc())
        .limit(1)
    )
    next_row = (await db.execute(next_q)).first()
    next_event: NextEvent | None = None
    if next_row is not None:
        s, name, color = next_row
        # D-Day: 자정 기준 일수 차
        s_date = s.due_date.replace(hour=0, minute=0, second=0, microsecond=0)
        d_day = (s_date - today_start).days
        next_event = NextEvent(
            id=s.id, title=s.title, type=s.type, due_date=s.due_date,
            d_day=d_day, course_id=s.course_id, course_name=name, course_color=color,
        )

    return HomeDashboardResponse(
        today_schedules=today_schedules,
        upcoming_todos=upcoming_todos,
        this_week_summary=this_week_summary,
        next_event=next_event,
    )
