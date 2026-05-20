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
    course_id: UUID
    course_name: str
    course_color: str | None
    title: str
    type: str
    due_date: datetime
    description: str | None
    is_auto: bool
    created_at: datetime

    model_config = {"from_attributes": True}
