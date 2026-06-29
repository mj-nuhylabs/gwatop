"""schedule → todos 자동 생성 규칙.

정책 (2026-06-29 변경):
- 실라버스에 적힌 일정(시험/과제)을 **그 당일에 한 건만** todo 로 올린다.
  (이전엔 시험마다 D-14/7/3/1 "복습", 과제마다 D-7/3/1 "작업" 식으로 여러 개를
   자동 생성했는데, 사용자가 복습/대비 todo 도배를 원치 않아 제거했다.)
- exam/assignment 만 todo 를 만든다. 그 외(lecture/meeting/upload/custom)는 생성 없음.
- todo 제목은 일정 제목 그대로(예: "Exam 1"). 접미사("복습"/"작업") 없음.
"""
from __future__ import annotations

from app.models.schedule import Schedule


# 일정 종류별 todo 우선순위 — 그 날이 실제 마감/시험일이므로 시험은 높게.
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
    priority = _PRIORITY_BY_TYPE.get(schedule.type)
    if priority is None:
        return []
    return [
        {
            "title": schedule.title,
            "due_date": schedule.due_date,
            "priority": priority,
            "course_id": schedule.course_id,
            "schedule_id": schedule.id,
            "is_auto": True,
        }
    ]
