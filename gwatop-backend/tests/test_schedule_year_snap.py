"""_snap_year_to_semester — 강의계획서 '연도 오타' 보정 검증.

실제 케이스: 2026 여름학기 계획서인데 시험만 이전 학기(2025) 연도로 복사돼
'중간고사_2025.07.08', '기말고사_2025.07.20' 로 적힌 경우 → 파서가 1년 과거로
등록해 캘린더/할일이 D+365 로 뜨던 버그.
"""

from __future__ import annotations

from datetime import date, datetime

from app.tasks.file_tasks import _snap_year_to_semester


def test_exam_year_typo_snapped_forward():
    # 2026 여름학기(시작 6/29)인데 시험이 2025 로 적힘 → 2026 으로 보정.
    start = date(2026, 6, 29)
    assert _snap_year_to_semester(datetime(2025, 7, 8), start) == datetime(2026, 7, 8)
    assert _snap_year_to_semester(datetime(2025, 7, 20), start) == datetime(2026, 7, 20)


def test_in_term_date_unchanged():
    start = date(2026, 6, 29)
    assert _snap_year_to_semester(datetime(2026, 7, 8), start) == datetime(2026, 7, 8)


def test_winter_session_next_year_not_touched():
    # 겨울 계절학기: 12월 시작 → 1월 시험은 정상적으로 다음 해. 건드리면 안 된다.
    start = date(2026, 12, 20)
    assert _snap_year_to_semester(datetime(2027, 1, 15), start) == datetime(2027, 1, 15)


def test_within_margin_before_start_unchanged():
    # 학기 시작 14일 이내(오리엔테이션 등) 는 보정 안 함.
    start = date(2026, 6, 29)
    assert _snap_year_to_semester(datetime(2026, 6, 24), start) == datetime(2026, 6, 24)


def test_two_years_off_snapped():
    start = date(2026, 6, 29)
    assert _snap_year_to_semester(datetime(2024, 7, 8), start) == datetime(2026, 7, 8)


def test_leap_day_snapped_to_feb28_on_nonleap():
    # 2/29(윤년) 를 비윤년으로 당기면 2/28 로 안전 조정.
    start = date(2026, 1, 10)
    assert _snap_year_to_semester(datetime(2024, 2, 29), start) == datetime(2026, 2, 28)


def test_none_passthrough():
    assert _snap_year_to_semester(None, date(2026, 6, 29)) is None


def test_accepts_datetime_semester_start():
    # semester_start 가 datetime 이어도 date 로 안전 변환.
    assert _snap_year_to_semester(datetime(2025, 7, 8), datetime(2026, 6, 29, 0, 0)) == datetime(2026, 7, 8)
