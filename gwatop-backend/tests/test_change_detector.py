"""Stage 3 변경 탐지의 순수 로직 — 키워드 게이트 + apply 파서 (LLM 없음)."""
from datetime import datetime

from app.services.change_detector import (
    has_change_signal,
    parse_class_time,
    parse_due_date,
)


def test_keyword_gate_hits_on_change_words():
    assert has_change_signal("과제 마감이 4월 22일로 연기되었습니다")
    assert has_change_signal("이번 주 강의실이 302호로 변경됩니다")
    assert has_change_signal("휴강 공지: 다음 주 보강 예정")


def test_keyword_gate_hits_on_new_assignment_announcement():
    # 강의자료에 뜬 새 과제 공지 — '변경' 단어가 없어도 '과제/제출/마감' 으로 게이트 통과.
    # (예비과 PDF 실제 문구: "과제공지(7월5일까지제출)")
    assert has_change_signal("과제공지(7월5일까지제출)")
    assert has_change_signal("이번 주 과제: 7/5 제출")
    assert has_change_signal("레포트 마감 7월 10일")


def test_keyword_gate_misses_plain_content():
    assert not has_change_signal("4주차 연쇄법칙 정리와 예제")
    assert not has_change_signal("스페인어 알파벳과 발음, 이중모음 연습")
    assert not has_change_signal("")
    assert not has_change_signal(None)


def test_parse_class_time():
    assert parse_class_time("월 14:00-15:30") == {
        "day": "MON", "start_time": "14:00", "end_time": "15:30",
    }
    # 한 자리 시(9:00)도 0 패딩, 물결 구분자도 허용.
    assert parse_class_time("수 9:00 ~ 10:30") == {
        "day": "WED", "start_time": "09:00", "end_time": "10:30",
    }
    # 시간이 하나뿐이면 강의시간으로 보지 않는다.
    assert parse_class_time("월요일 14:00") is None
    # 강의실 문자열은 강의시간이 아니다.
    assert parse_class_time("공학관 302") is None


def test_parse_due_date():
    assert parse_due_date("2025-04-22", 2024) == datetime(2025, 4, 22, 23, 59)
    # 연도 없으면 fallback_year 사용.
    assert parse_due_date("4월 22일", 2025) == datetime(2025, 4, 22, 23, 59)
    # 시각이 있으면 반영.
    assert parse_due_date("4/22 18:00", 2025) == datetime(2025, 4, 22, 18, 0)
    # 날짜를 못 찾으면 None.
    assert parse_due_date("마감 미정", 2025) is None
