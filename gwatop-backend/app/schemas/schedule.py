from __future__ import annotations

from datetime import datetime
from typing import Literal
from uuid import UUID

from pydantic import BaseModel


ScheduleType = Literal["lecture", "assignment", "exam", "meeting", "upload", "custom"]


class ScheduleCreate(BaseModel):
    course_id: UUID
    title: str
    type: ScheduleType
    due_date: datetime
    description: str | None = None


class ScheduleUpdate(BaseModel):
    course_id: UUID | None = None
    title: str | None = None
    type: ScheduleType | None = None
    due_date: datetime | None = None
    description: str | None = None


class ScheduleResponse(BaseModel):
    id: UUID
    # 외부(Apple 캘린더) 일정은 과목이 없어 course_id/course_name 가 null 이다.
    course_id: UUID | None = None
    course_name: str | None = None
    course_color: str | None = None
    title: str
    type: str
    due_date: datetime
    # 종료 시각(주로 외부 Apple 일정). 없으면 null.
    end_date: datetime | None = None
    description: str | None
    is_auto: bool
    source: str | None = None
    external_id: str | None = None
    created_at: datetime

    model_config = {"from_attributes": True}


class ExternalEventItem(BaseModel):
    """앱이 올리는 Apple 캘린더 이벤트 한 건. start_date 를 due_date 로 저장한다."""
    external_id: str
    title: str
    start_date: datetime
    end_date: datetime | None = None
    location: str | None = None
    all_day: bool = False


class ExternalEventSyncRequest(BaseModel):
    """source 의 외부 일정 전체 스냅샷. 서버는 이 목록으로 upsert + 누락분 삭제(전치환)."""
    source: str = "apple_calendar"
    events: list[ExternalEventItem]


class ExternalEventSyncResult(BaseModel):
    created: int
    updated: int
    deleted: int


class CalendarDaySummary(BaseModel):
    date: str  # YYYY-MM-DD
    total: int
    by_type: dict[str, int]  # {"exam": 1, "assignment": 2, ...}


class CalendarSummaryResponse(BaseModel):
    start: datetime
    end: datetime
    days: list[CalendarDaySummary]
