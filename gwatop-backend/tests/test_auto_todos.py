"""자동 할일 생성 정책 검증.

정책(2026-07-01): 시험 복습 할일은 기본 OFF — 시험 '일정'만 남기고 복습 리마인더는
만들지 않는다. 과제 마감 '작업' 할일은 유지.
"""

from __future__ import annotations

from app.core.config import settings
from app.services.todo_generator import ASSIGNMENT_SPECS, EXAM_SPECS, specs_for


def test_exam_review_todos_off_by_default():
    assert settings.AUTO_EXAM_REVIEW_TODOS is False
    assert specs_for("exam") == []


def test_exam_review_todos_can_be_reenabled(monkeypatch):
    monkeypatch.setattr(settings, "AUTO_EXAM_REVIEW_TODOS", True)
    assert specs_for("exam") == EXAM_SPECS


def test_assignment_todo_is_single_on_due_date():
    # 과제는 마감일 당일 할일 1개만 (준비 리마인더 없음).
    assert specs_for("assignment") == ASSIGNMENT_SPECS
    assert len(ASSIGNMENT_SPECS) == 1
    spec = ASSIGNMENT_SPECS[0]
    assert spec.days_before == 0  # 마감일 당일
    assert spec.label == ""       # 접미사 없음 → 제목은 과제 이름 그대로


def test_build_auto_todos_assignment_title_and_date():
    from datetime import datetime
    from types import SimpleNamespace
    from app.services.todo_generator import build_auto_todos

    sched = SimpleNamespace(
        type="assignment", title="과제",
        due_date=datetime(2026, 7, 5, 23, 59),
        course_id="c", id="s",
    )
    todos = build_auto_todos(sched)
    assert len(todos) == 1
    assert todos[0]["title"] == "과제"                      # 접미사 없이 이름 그대로
    assert todos[0]["due_date"] == datetime(2026, 7, 5, 23, 59)  # 마감일 당일


def test_other_types_no_todos():
    for t in ("lecture", "meeting", "upload", "custom", ""):
        assert specs_for(t) == []
