"""schedule → todos 자동 생성 규칙.

정책 (2026-07-01 갱신 #2):
- exam:       'D-14/7/3/1 시험 복습' 할일 — 기본 OFF (settings.AUTO_EXAM_REVIEW_TODOS).
              시험은 이벤트라 '일정'(캘린더)만 남기고 과제탭엔 할일을 만들지 않는다.
- assignment: 과제 **마감일 당일에 할일 1개**만 (과제 자체). 과거엔 D-7/3/1 준비 리마인더
              3개를 만들었으나, '과제는 7/5인데 왜 6/28·7/2·7/4가 뜨냐'는 피드백에 따라
              마감일 하나로 단순화. 제목은 과제 이름 그대로(접미사 없음).
- 그 외 type (lecture/meeting/upload/custom): 자동 생성 없음
"""
from __future__ import annotations

from dataclasses import dataclass
from datetime import timedelta

from app.core.config import settings
from app.models.schedule import Schedule


@dataclass(frozen=True)
class TodoSpec:
    days_before: int
    priority: str
    label: str  # 할일 제목 접미사. ""(빈 문자열)이면 일정 제목 그대로.


EXAM_SPECS: list[TodoSpec] = [
    TodoSpec(14, "low", "복습"),
    TodoSpec(7, "medium", "복습"),
    TodoSpec(3, "high", "복습"),
    TodoSpec(1, "high", "복습"),
]

# 과제는 마감일 당일 할일 1개 (준비 리마인더 없음). 제목은 과제 이름 그대로.
ASSIGNMENT_SPECS: list[TodoSpec] = [
    TodoSpec(0, "high", ""),
]


def specs_for(schedule_type: str) -> list[TodoSpec]:
    if schedule_type == "exam":
        # 시험 복습 할일은 기본 OFF — 시험 '일정'만 남기고 복습 리마인더는 만들지 않는다.
        return EXAM_SPECS if settings.AUTO_EXAM_REVIEW_TODOS else []
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
        # label 이 비면 일정 제목 그대로 (예: "과제"), 있으면 접미사 부착 (예: "중간고사 복습").
        title = f"{schedule.title} {spec.label}".strip()
        todos.append(
            {
                "title": title,
                "due_date": due,
                "priority": spec.priority,
                "course_id": schedule.course_id,
                "schedule_id": schedule.id,
                "is_auto": True,
            }
        )
    return todos
