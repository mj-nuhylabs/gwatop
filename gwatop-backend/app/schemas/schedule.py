from __future__ import annotations

from datetime import datetime
from uuid import UUID

from pydantic import BaseModel


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
