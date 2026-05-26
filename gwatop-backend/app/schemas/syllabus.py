from __future__ import annotations

from datetime import date, time
from typing import Literal

from pydantic import BaseModel, Field, field_validator, model_validator


Weekday = Literal["MON", "TUE", "WED", "THU", "FRI", "SAT", "SUN"]


class ParsedClassTime(BaseModel):
    day: Weekday
    start_time: time
    end_time: time

    @field_validator("end_time")
    @classmethod
    def _end_after_start(cls, v: time, info):
        start = info.data.get("start_time")
        if start and v <= start:
            raise ValueError("end_time must be after start_time")
        return v


class ParsedCourseMeta(BaseModel):
    name: str = Field(..., description="과목명")
    professor: str | None = None
    credit: int | None = Field(None, ge=0, le=10)
    location: str | None = None
    class_times: list[ParsedClassTime] = Field(default_factory=list)
    total_weeks: int = Field(16, ge=1, le=30)

    @model_validator(mode="before")
    @classmethod
    def _drop_incomplete_class_times(cls, data):
        # LLM이 두 번째 슬롯을 채우려고 start/end를 null로 반환하는 경우가 있어 사전에 드롭
        if not isinstance(data, dict):
            return data
        items = data.get("class_times")
        if isinstance(items, list):
            data["class_times"] = [
                it for it in items
                if isinstance(it, dict) and it.get("start_time") and it.get("end_time") and it.get("day")
            ]
        return data


class ParsedWeek(BaseModel):
    week_number: int = Field(..., ge=1, le=30)
    topic: str | None = None
    notes: str | None = None


class ParsedExam(BaseModel):
    title: str
    exam_date: date | None = None
    start_time: time | None = None
    end_time: time | None = None
    location: str | None = None
    description: str | None = None


class ParsedAssignment(BaseModel):
    title: str
    due_date: date | None = None
    description: str | None = None


class ParsedSyllabus(BaseModel):
    course: ParsedCourseMeta
    weeks: list[ParsedWeek] = Field(default_factory=list)
    exams: list[ParsedExam] = Field(default_factory=list)
    assignments: list[ParsedAssignment] = Field(default_factory=list)
    confidence: float = Field(0.0, ge=0.0, le=1.0)
    warnings: list[str] = Field(default_factory=list)


class SyllabusParseUsage(BaseModel):
    model: str
    prompt_tokens: int
    completion_tokens: int
    total_tokens: int


class SyllabusParseResult(BaseModel):
    syllabus: ParsedSyllabus
    usage: SyllabusParseUsage
