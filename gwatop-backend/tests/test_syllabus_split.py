"""BUG-5 회귀 — _split_segments 가 'M/D' 날짜를 파괴하지 않는다.

비고 셀을 여러 일정으로 쪼갤 때 '/' 로도 split 했는데, 한국 강의계획서의 대표
날짜 표기 '6/22' 가 ['6','22…'] 로 쪼개져 누락 일정 회수가 무력화됐다.
숫자 사이 '/' 는 split 하지 않도록 고쳤다.
"""
from datetime import date

from app.services.syllabus_parser import _extract_first_date, _split_segments


def test_md_dates_preserved_through_split():
    notes = "6/10 (수) 퀴즈 1; 6/12 (금) 과제 1 출제"
    segs = _split_segments(notes)
    assert segs == ["6/10 (수) 퀴즈 1", "6/12 (금) 과제 1 출제"]
    # 각 조각에서 M/D 날짜가 그대로 읽혀야 한다.
    assert _extract_first_date(segs[0], 2026) == date(2026, 6, 10)
    assert _extract_first_date(segs[1], 2026) == date(2026, 6, 12)


def test_slash_still_splits_between_nondigits():
    # 숫자 사이가 아닌 '/' 는 여전히 구분자로 동작.
    assert _split_segments("퀴즈 / 과제") == ["퀴즈", "과제"]


def test_semicolon_and_korean_and_split():
    assert _split_segments("6/22 및 6/25") == ["6/22", "6/25"]
    assert _split_segments("중간고사 6/22\n기말고사 6/25") == ["중간고사 6/22", "기말고사 6/25"]
