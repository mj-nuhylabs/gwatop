from pydantic import BaseModel, field_validator
from datetime import datetime
from uuid import UUID
from typing import Any
import re


class CourseCreate(BaseModel):
    name: str
    professor: str | None = None
    color: str = "#4F8EF7"
    schedule: list[Any] | None = None

    @field_validator("color")
    @classmethod
    def validate_color(cls, v):
        if not re.match(r"^#[0-9A-Fa-f]{6}$", v):
            raise ValueError("color must be a valid hex code like #4F8EF7")
        return v


class CourseUpdate(BaseModel):
    name: str | None = None
    professor: str | None = None
    color: str | None = None
    schedule: list[Any] | None = None

    @field_validator("color")
    @classmethod
    def validate_color(cls, v):
        if v is not None and not re.match(r"^#[0-9A-Fa-f]{6}$", v):
            raise ValueError("color must be a valid hex code like #4F8EF7")
        return v


class CourseResponse(BaseModel):
    id: UUID
    semester_id: UUID
    name: str
    professor: str | None
    color: str | None
    schedule: list[Any] | None
    created_at: datetime

    model_config = {"from_attributes": True}
