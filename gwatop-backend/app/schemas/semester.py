from pydantic import BaseModel, field_validator
from datetime import date, datetime
from uuid import UUID


class SemesterCreate(BaseModel):
    name: str
    start_date: date
    end_date: date
    is_active: bool = False

    @field_validator("end_date")
    @classmethod
    def end_after_start(cls, v, info):
        if "start_date" in info.data and v <= info.data["start_date"]:
            raise ValueError("end_date must be after start_date")
        return v


class SemesterUpdate(BaseModel):
    name: str | None = None
    start_date: date | None = None
    end_date: date | None = None
    is_active: bool | None = None


class SemesterResponse(BaseModel):
    id: UUID
    user_id: UUID
    name: str
    start_date: date
    end_date: date
    is_active: bool
    created_at: datetime

    model_config = {"from_attributes": True}
