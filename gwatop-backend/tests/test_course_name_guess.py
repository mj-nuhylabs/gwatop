"""BUG-7 회귀 — 파일명에서 과목명 추정.

단독 '강' 패턴이 '강화학습' 같은 과목명을 통째로 노이즈로 버리고, '3주차' 처럼
숫자가 앞에 붙은 주차 토큰은 노이즈로 안 걸러져 과목명을 오염시켰다.
"""
from app.services.auto_classifier import guess_course_name_from_filename


def test_korean_subject_not_dropped_by_bare_gang():
    # '강' 으로 시작하는 과목명이 통째로 버려지면 안 된다.
    assert guess_course_name_from_filename("강화학습_3주차.pdf") == "강화학습"


def test_numbered_week_token_is_noise():
    # '03주차' 같은 숫자-주차 토큰은 노이즈로 제거돼야 한다.
    assert guess_course_name_from_filename("[자료구조] 03주차 강의자료.pdf") == "자료구조"
    assert guess_course_name_from_filename("운영체제_5강.pdf") == "운영체제"


def test_existing_examples_still_work():
    assert guess_course_name_from_filename("DS_HW3.pdf") == "DS"
