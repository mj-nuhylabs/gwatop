"""schedule → todos 자동 생성 규칙.

정책 (2026-07-01 갱신 #2):
- exam:       'D-14/7/3/1 시험 복습' 할일 — 기본 OFF (settings.AUTO_EXAM_REVIEW_TODOS).
              시험은 이벤트라 '일정'(캘린더)만 남기고 과제탭엔 할일을 만들지 않는다.
- assignment: 과제 **마감일 당일에 할일 1개**만 (과제 자체). 과거엔 D-7/3/1 준비 리마인더
              3개를 만들었으나, '과제는 7/5인데 왜 6/28·7/2·7/4가 뜨냐'는 피드백에 따라
              마감일 하나로 단순화. 제목은 과제 이름 그대로(접미사 없음).
- 그 외 type (lecture/meeting/upload/custom): 자동 생성 없음
- 강의계획서/강의자료에 **정확한 날짜가 안 적힌** 시험/과제는 캘린더(schedule)에는 못 올리지만
  날짜 미지정(due_date=None) todo 로 해당 과목에 추가한다 — build_undated_todo 참고.
"""
from __future__ import annotations

from dataclasses import dataclass
from datetime import timedelta
from uuid import UUID

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


# 날짜 미지정(build_undated_todo) 전용 우선순위 — 캘린더에 못 올린 시험/과제를
# 과제탭에 한 건 남길 때 사용. 복습 정책(specs_for)과 무관하게 항상 생성한다.
_PRIORITY_BY_TYPE = {
    "exam": "high",
    "assignment": "medium",
}


def build_auto_todos(schedule: Schedule) -> list[dict]:
    """schedule 하나에 대응되는 auto todo dict 목록.

    이제 일정 당일(due_date)에 **한 건만** 만든다. 반환 dict 키:
    title, due_date, priority, course_id, schedule_id, is_auto.
    DB insert 는 호출자가 책임진다.

    exam/assignment 가 아니면 빈 리스트.
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


def build_undated_todo(course_id: UUID, title: str, sched_type: str) -> dict | None:
    """날짜 미지정 시험/과제용 auto todo dict.

    강의계획서/강의자료에 시험·과제가 적혀 있으나 정확한 날짜를 못 구한 경우,
    캘린더(schedule)에는 못 올리므로 due_date=None, schedule_id=None 인 todo 로만 만든다.
    exam/assignment 가 아니면 None.
    """
    priority = _PRIORITY_BY_TYPE.get(sched_type)
    if priority is None:
        return None
    return {
        "title": title,
        "due_date": None,
        "priority": priority,
        "course_id": course_id,
        "schedule_id": None,
        "is_auto": True,
    }
