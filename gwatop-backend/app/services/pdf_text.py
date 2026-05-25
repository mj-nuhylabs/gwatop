"""PDF → 평문 텍스트 추출 + 강의계획서 파싱용 전처리.

Day 3 오전(PyMuPDF 텍스트 추출 Celery 태스크)에서 사용할 헬퍼.
syllabus_parser.parse_syllabus(text=...) 의 입력으로 사용된다.

clean_syllabus_text 는 LLM 입력 토큰을 줄이기 위해 반복 헤더/푸터와
파싱과 무관한 후반 섹션(참고문헌, 성적평가 등)을 제거한다.
"""

from __future__ import annotations

import re
from collections import Counter

import fitz  # PyMuPDF


def extract_text_from_pdf_bytes(data: bytes) -> str:
    with fitz.open(stream=data, filetype="pdf") as doc:
        return "\n\n".join(page.get_text("text") for page in doc)


def extract_text_from_pdf_path(path: str) -> str:
    with fitz.open(path) as doc:
        return "\n\n".join(page.get_text("text") for page in doc)


# ---------- 강의계획서 LLM 파싱용 전처리 ----------

# 일정 정보와 무관한 섹션 시작 키워드. 라인 시작에서 매칭하면 그 라인 이후를 잘라낸다.
# 강의계획서는 보통 [표지 → 강의 소개 → 주차별 일정 → (이 아래는 파서가 필요 없음)] 순서.
_CUTOFF_MARKERS = (
    "참고문헌",
    "참고도서",
    "주교재",
    "부교재",
    "교재 및 참고문헌",
    "성적평가",
    "성적 평가",
    "평가 방법",
    "수업 방침",
    "수업방침",
    "비고 및 안내",
    "기타사항",
    "기타 사항",
    "수강생 유의사항",
    "표절",
    "출석",
    "장애학생",
    "코로나",
    "기숙사",
)

# 반복 헤더로 간주할 최소 등장 횟수. PDF 페이지마다 학교명/과목코드 반복되는 케이스.
_HEADER_REPEAT_THRESHOLD = 3
# 짧고 자주 반복되는 라인만 헤더로 간주 (긴 라인은 본문일 가능성).
_HEADER_MAX_LEN = 80
# 명확한 페이지 번호 패턴.
_PAGE_NUM_RE = re.compile(r"^\s*-?\s*\d{1,3}\s*-?\s*$")
# "Page N of M" 류.
_PAGE_LABEL_RE = re.compile(r"^\s*(?:page|p\.?)\s*\d+\s*(?:/|of)\s*\d+\s*$", re.IGNORECASE)
# 연속 빈 줄 압축.
_MULTI_BLANK_RE = re.compile(r"\n{3,}")


def clean_syllabus_text(raw: str) -> str:
    """강의계획서 LLM 파싱 전 텍스트 전처리.

    적용 순서:
      1) 페이지 번호 라인 제거
      2) 자주 반복되는 짧은 라인(헤더/푸터) 제거
      3) 일정과 무관한 후반 섹션 cut (`참고문헌`, `성적평가` 등이 라인 시작에서 등장하는 위치)
      4) 연속 빈 줄 압축

    원문이 짧거나 cut 위치가 너무 앞이면 잘라내기를 적용하지 않는다(데이터 손실 방지).
    토큰 30% 정도 감소가 목표.
    """
    if not raw:
        return raw

    lines = raw.splitlines()

    # (1) 페이지 번호 / "Page N of M" 라인 제거
    lines = [ln for ln in lines if not _PAGE_NUM_RE.match(ln) and not _PAGE_LABEL_RE.match(ln)]

    # (2) 반복 헤더/푸터 제거 — 짧고 자주 등장하는 라인만
    stripped_counts = Counter(ln.strip() for ln in lines if ln.strip())
    repeated = {
        s for s, c in stripped_counts.items()
        if c >= _HEADER_REPEAT_THRESHOLD and len(s) <= _HEADER_MAX_LEN
    }
    if repeated:
        lines = [ln for ln in lines if ln.strip() not in repeated]

    text = "\n".join(lines)

    # (3) 후반 섹션 cut — 본문의 80% 이전 위치에 cutoff 마커가 라인 시작에 등장하면 잘라낸다.
    # 너무 일찍 잘라내면 일정 섹션이 사라질 수 있으므로 본문 길이 60% 지점 이전은 보호.
    min_keep = max(int(len(text) * 0.6), 1000)
    cut_at: int | None = None
    for marker in _CUTOFF_MARKERS:
        # 라인 시작 또는 공백/구두점 뒤에서만 매칭 (본문 안 단어 매칭 방지)
        pattern = re.compile(rf"(?:^|\n)\s*{re.escape(marker)}", re.MULTILINE)
        m = pattern.search(text, pos=min_keep)
        if m and (cut_at is None or m.start() < cut_at):
            cut_at = m.start()
    if cut_at is not None:
        text = text[:cut_at].rstrip()

    # (4) 연속 빈 줄 압축
    text = _MULTI_BLANK_RE.sub("\n\n", text)

    return text.strip()
