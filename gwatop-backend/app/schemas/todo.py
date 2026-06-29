from __future__ import annotations

from datetime import datetime
from typing import Literal
from uuid import UUID

from pydantic import BaseModel


Priority = Literal["low", "medium", "high"]


class TodoCreate(BaseModel):
    course_id: UUID
    schedule_id: UUID | None = None
    title: str
    due_date: datetime
    priority: Priority = "low"


class TodoUpdate(BaseModel):
    title: str | None = None
    due_date: datetime | None = None
    priority: Priority | None = None
    is_done: bool | None = None


class TodoResponse(BaseModel):
    id: UUID
    course_id: UUID
    schedule_id: UUID | None
    course_name: str
    course_color: str | None
    title: str
    due_date: datetime | None
    priority: str
    is_done: bool
    is_auto: bool
    created_at: datetime

    model_config = {"from_attributes": True}
