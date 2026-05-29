"""파일명에서 주차(week) 번호를 추출하는 정규식 분류기.

업로더가 보통 ``[과목]_3주차_세션자료.pdf`` / ``week5.pptx`` / ``ch7_intro.pdf``
같은 패턴으로 파일명을 쓴다. 이런 명시적 단서가 있으면 임베딩 비교보다
훨씬 정확하므로 1차 분류기로 사용한다.
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from pathlib import PurePosixPath


# 우선순위가 높은 패턴부터 정렬해두면 더 구체적인 표현이 먼저 매칭된다.
# 모든 패턴은 정수 1~30 범위로 캡처 그룹을 잡아야 한다.
# 숫자 캡처 끝을 \b 대신 (?!\d) 로 둔다 — \b 는 'week5_intro' 처럼 숫자 뒤에
# '_'(정규식상 word 문자)가 오면 경계가 없어 매칭이 실패한다. (?!\d) 는 뒤가
# 또 다른 숫자만 아니면(언더스코어/점/하이픈/문자/끝 모두) 허용하므로 부분 숫자
# 매칭은 막으면서 '_' 구분 파일명을 정상 인식한다.
_WEEK_PATTERNS: list[tuple[str, re.Pattern[str]]] = [
    # "3주차", "제3주차", "3 주차"
    ("주차", re.compile(r"(?:제\s*)?(\d{1,2})\s*주\s*차", re.IGNORECASE)),
    # "주차3", "주 3"
    ("주차역", re.compile(r"주\s*차?\s*(\d{1,2})", re.IGNORECASE)),
    # "week 5", "wk5", "w5"
    ("week", re.compile(r"\b(?:week|wk|w)\s*[-_# ]?\s*(\d{1,2})(?!\d)", re.IGNORECASE)),
    # "chapter 4", "ch4", "ch_4"
    ("chapter", re.compile(r"\b(?:chapter|chap|ch)\s*[-_# ]?\s*(\d{1,2})(?!\d)", re.IGNORECASE)),
    # "lecture 6", "lec6"
    ("lecture", re.compile(r"\b(?:lecture|lec)\s*[-_# ]?\s*(\d{1,2})(?!\d)", re.IGNORECASE)),
    # 마지막 fallback — 파일명 맨 앞의 "01_", "02-", "03." 같은 숫자 prefix.
    # 가장 약한 신호이므로 confidence를 따로 낮춰서 부여한다.
    ("prefix", re.compile(r"^\s*(\d{1,2})\s*[._\-]")),
]


# 패턴별 기본 confidence. 가장 명시적인 한국어 "N주차"가 가장 강하다.
_PATTERN_CONFIDENCE: dict[str, float] = {
    "주차": 0.95,
    "주차역": 0.90,
    "week": 0.92,
    "chapter": 0.88,
    "lecture": 0.85,
    "prefix": 0.55,
}


@dataclass(frozen=True)
class FilenameClassification:
    week_number: int
    confidence: float
    pattern: str
    matched_text: str


def classify_by_filename(filename: str) -> FilenameClassification | None:
    """파일명에서 주차 번호를 추정한다.

    Args:
        filename: 원본 파일명 (확장자 포함). 경로가 섞여 있어도 basename으로 자른다.

    Returns:
        매칭 실패 시 None. 성공 시 (week, confidence, pattern).
    """
    if not filename:
        return None

    name = PurePosixPath(filename).name
    # 확장자 분리 — "week3.pdf" 의 .pdf 부분에 숫자 prefix가 매칭되지 않도록.
    stem, _, _ = name.rpartition(".")
    candidate = stem or name

    for pattern_name, regex in _WEEK_PATTERNS:
        match = regex.search(candidate)
        if not match:
            continue
        try:
            week = int(match.group(1))
        except (ValueError, IndexError):
            continue
        if not (1 <= week <= 30):
            continue
        return FilenameClassification(
            week_number=week,
            confidence=_PATTERN_CONFIDENCE[pattern_name],
            pattern=pattern_name,
            matched_text=match.group(0),
        )
    return None
