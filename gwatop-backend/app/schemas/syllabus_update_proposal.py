from __future__ import annotations

import uuid
from datetime import datetime

from pydantic import BaseModel, ConfigDict


# field 키 → 한국어 라벨 (UI 표기용).
FIELD_LABELS = {
    "class_time": "강의시간",
    "classroom": "강의실",
    "assignment_due": "과제·시험 마감",
}


class ProposalResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    course_id: uuid.UUID
    course_name: str | None = None
    file_id: uuid.UUID | None = None
    schedule_id: uuid.UUID | None = None
    field: str
    field_label: str
    target_title: str | None = None
    old_value: str | None = None
    new_value: str
    evidence: str
    confidence: float
    status: str
    created_at: datetime
