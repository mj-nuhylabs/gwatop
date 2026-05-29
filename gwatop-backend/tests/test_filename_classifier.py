"""BUG-6 회귀 — 파일명 주차 분류기의 숫자 끝 매칭.

week/chapter/lecture 패턴 끝이 \\b 이면 'week5_intro' 처럼 숫자 뒤에 '_'(word문자)가
오는 가장 흔한 파일명에서 매칭이 실패했다. (?!\\d) 로 바꿔 부분 숫자 매칭은 막으면서
'_' 구분 파일명을 정상 인식한다.
"""
from app.services.filename_classifier import classify_by_filename


def test_underscore_separated_filenames_match():
    cases = {
        "week5_intro.pdf": 5,
        "ch7_notes.pdf": 7,
        "lecture3_slides.pptx": 3,
        "week_5_intro.pdf": 5,
        "ch7_intro.pdf": 7,  # 모듈 docstring 이 지원 예시로 명시한 케이스
    }
    for name, week in cases.items():
        r = classify_by_filename(name)
        assert r is not None, f"{name} 가 매칭되지 않음"
        assert r.week_number == week, f"{name}: {r.week_number} != {week}"


def test_existing_separators_still_match():
    cases = {"week5.pdf": 5, "week5-intro.pdf": 5, "3주차_자료.pdf": 3, "chapter4.pdf": 4}
    for name, week in cases.items():
        r = classify_by_filename(name)
        assert r is not None and r.week_number == week, f"{name}: {r}"


def test_long_number_not_partially_matched():
    # 1~2자리 부분 매칭 방지: 'week123' 은 None 이어야 한다.
    assert classify_by_filename("week123.pdf") is None
