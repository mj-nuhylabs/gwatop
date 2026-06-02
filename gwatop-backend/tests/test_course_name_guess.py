"""BUG-7 회귀 — 파일명에서 과목명 추정.

단독 '강' 패턴이 '강화학습' 같은 과목명을 통째로 노이즈로 버리고, '3주차' 처럼
숫자가 앞에 붙은 주차 토큰은 노이즈로 안 걸러져 과목명을 오염시켰다.
"""
from app.services.auto_classifier import (
    guess_course_identity_from_text,
    guess_course_name_from_filename,
)


def test_korean_subject_not_dropped_by_bare_gang():
    # '강' 으로 시작하는 과목명이 통째로 버려지면 안 된다.
    assert guess_course_name_from_filename("강화학습_3주차.pdf") == "강화학습"


def test_numbered_week_token_is_noise():
    # '03주차' 같은 숫자-주차 토큰은 노이즈로 제거돼야 한다.
    assert guess_course_name_from_filename("[자료구조] 03주차 강의자료.pdf") == "자료구조"
    assert guess_course_name_from_filename("운영체제_5강.pdf") == "운영체제"


def test_existing_examples_still_work():
    assert guess_course_name_from_filename("DS_HW3.pdf") == "DS"


def test_sequence_code_token_is_noise():
    # 'C1' 같은 분반/순번 마커는 과목명으로 새지 않아야 한다.
    # 'lecture_C1_01_html_css' → 'C1 html' 이라는 가짜 과목명이 만들어지던 버그.
    assert guess_course_name_from_filename("lecture_C1_01_html_css.pdf") == "html css"


# ---------- 본문 머리글 기반 과목 정체성 추출 ----------

def test_identity_from_header_korean():
    # 강의자료 머리글의 "<과목명> (<코드>)" 에서 과목명+코드 추출.
    text = (
        "HTML5 & CSS3 기초\n"
        "Lecture 01 — 시맨틱 마크업과 반응형 디자인\n"
        "웹 개발 실무 (CSE 3401)\n"
        "1주차 강의자료\n"
    )
    assert guess_course_identity_from_text(text) == ("웹 개발 실무", "CSE 3401")


def test_identity_from_header_english():
    text = (
        "Email Writing Fundamentals\n"
        "Lecture 02 — Writing Professional Emails\n"
        "Business English Conversation (ENG 2305)\n"
        "Week 2 Materials\n"
    )
    assert guess_course_identity_from_text(text) == (
        "Business English Conversation",
        "ENG 2305",
    )


def test_identity_ignores_tech_terms():
    # 'CSS3','HTML5','ES6' 처럼 숫자 1자리 기술용어는 과목코드로 오인하면 안 된다.
    text = "HTML5 & CSS3 기초\nES6 문법 정리\n자바스크립트 핵심\n"
    assert guess_course_identity_from_text(text) == (None, None)
