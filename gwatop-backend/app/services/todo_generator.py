"""schedule → todos 자동 생성 규칙.

정책 (2026-05-21):
- exam:       D-14 (low), D-7 (medium), D-3 (high), D-1 (high)
- assignment: D-7 (medium), D-3 (high), D-1 (high)
- 그 외 type (lecture/meeting/upload/custom): 자동 생성 없음
"""
from __future__ import annotations

from dataclasses import dataclass
from datetime import timedelta

from app.models.schedule import Schedule


@dataclass(frozen=True)
class TodoSpec:
    days_before: int
    priority: str
    label: str  # "복습" / "작업"


EXAM_SPECS: list[TodoSpec] = [
    TodoSpec(14, "low", "복습"),
    TodoSpec(7, "medium", "복습"),
    TodoSpec(3, "high", "복습"),
    TodoSpec(1, "high", "복습"),
]

ASSIGNMENT_SPECS: list[TodoSpec] = [
    TodoSpec(7, "medium", "작업"),
    TodoSpec(3, "high", "작업"),
    TodoSpec(1, "high", "작업"),
]


def specs_for(schedule_type: str) -> list[TodoSpec]:
    if schedule_type == "exam":
        return EXAM_SPECS
    if schedule_type == "assignment":
        return ASSIGNMENT_SPECS
    return []


def build_auto_todos(schedule: Schedule) -> list[dict]:
    """schedule 하나에 대응되는 auto todo dict 목록.

    반환 dict 키: title, due_date, priority, course_id, schedule_id, is_auto.
    DB insert는 호출자가 책임진다.
    """
    specs = specs_for(schedule.type)
    todos: list[dict] = []
    for spec in specs:
        due = schedule.due_date - timedelta(days=spec.days_before)
        todos.append(
            {
                "title": f"{schedule.title} {spec.label}",
                "due_date": due,
                "priority": spec.priority,
                "course_id": schedule.course_id,
                "schedule_id": schedule.id,
                "is_auto": True,
            }
        )
    return todos
