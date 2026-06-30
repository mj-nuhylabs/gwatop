"""홈 대시보드 응답 스키마."""
from __future__ import annotations

from datetime import datetime
from uuid import UUID

from pydantic import BaseModel

from app.schemas.schedule import ScheduleResponse
from app.schemas.todo import TodoResponse


class WeekSummary(BaseModel):
    """이번 주(월~일) 할 일 통계."""
    total: int
    done: int
    rate: float  # 0.0 ~ 1.0


class NextEvent(BaseModel):
    """다가오는 가장 가까운 schedule (D-Day 카드용)."""
    id: UUID
    title: str
    type: str
    due_date: datetime
    d_day: int  # >=0 이면 미래/오늘, <0 이면 과거 (지금 시점엔 next라 보통 미래)
    # 외부(Apple) 일정이 next 가 될 수 있어 course 정보는 nullable.
    course_id: UUID | None = None
    course_name: str | None = None
    course_color: str | None = None


class HomeDashboardResponse(BaseModel):
    today_schedules: list[ScheduleResponse]
    upcoming_todos: list[TodoResponse]       # 미완료, priority high→date 정렬, 최대 10개
    this_week_summary: WeekSummary
    next_event: NextEvent | None
