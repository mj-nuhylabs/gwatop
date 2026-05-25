"""PDF → 평문 텍스트 추출 + 강의계획서 파싱용 전처리.

Day 3 오전(PyMuPDF 텍스트 추출 Celery 태스크)에서 사용할 헬퍼.
syllabus_parser.parse_syllabus(text=...) 의 입력으로 사용된다.

clean_syllabus_text 는 LLM 입력 토큰을 줄이기 위해 반복 헤더/푸터와
파싱과 무관한 후반 섹션(참고문헌, 성적평가 등)을 제거한다.

extract_tables_from_pdf 는 PyMuPDF find_tables() 로 표 구조를 직접 잡아
주차표를 ParsedWeek 로 채운다. 표가 깔끔하게 잡히면 LLM 호출의 weeks
부분을 통째로 생략할 수 있어 latency 가 절반 가까이 줄어든다.
"""

from __future__ import annotations

import logging
import re
from collections import Counter

import fitz  # PyMuPDF

from app.schemas.syllabus import ParsedWeek

logger = logging.getLogger(__name__)


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


# ---------- 강의계획서 표 추출 (PyMuPDF find_tables) ----------

# 컬럼 헤더 매칭 힌트. 대소문자 무시, 부분일치.
_WEEK_COL_HINTS = ("주차", "week", "회차", "주별")
_DATE_COL_HINTS = ("날짜", "일자", "기간", "date", "일시")
_TOPIC_COL_HINTS = ("주제", "내용", "강의주제", "강의 주제", "topic", "lecture", "강의내용", "수업내용")
_NOTE_COL_HINTS = ("비고", "과제", "시험", "note", "remark", "기타", "특이사항", "수업방법", "비 고")

# "1주차", "1주", "Week 1", "제1주" 등에서 주차 번호 추출.
_WEEK_NUM_RE = re.compile(
    r"(?:제\s*)?(\d{1,2})\s*(?:주\s*차?|주\b|week|wk)",
    re.IGNORECASE,
)

# 표 추출 신뢰 기준.
# 최소 행 수 — 너무 적으면 표가 부분만 잡힌 것일 수 있음.
_MIN_WEEK_ROWS = 5
# 최대 행 수 — 정상 학기는 16주 ± 알파. 30 넘으면 표 식별 오류일 가능성.
_MAX_WEEK_ROWS = 30
# 주차 번호 연속성 검사 — 1부터 시작해서 단조 증가 또는 거의 그래야 함.
# 중간에 몇 개 빠지는 건 허용 (휴강 등), 단 (max - min + 1) > 행 수 * 1.5 면 의심.
_CONSECUTIVE_TOLERANCE = 1.5


def extract_tables_from_pdf(pdf_bytes: bytes) -> list[ParsedWeek] | None:
    """강의계획서 PDF에서 주차표를 추출해 ParsedWeek list 로 반환.

    PyMuPDF 의 find_tables() 가 선/박스로 그려진 표를 셀 단위로 잡아내므로,
    LLM 이 평문에서 표를 "재구성"하는 출력 토큰을 절약할 수 있다.

    추출 결과를 신뢰할 수 있을 때만 list 를 반환한다:
      - 헤더 행에 "주차"/"주제" 컬럼이 식별됨
      - 데이터 행이 5~30개
      - 주차 번호가 1부터 거의 연속 (휴강 1-2주는 허용)

    실패 시 None — 호출 측은 기존 LLM 단일 호출 경로로 fallback.
    """
    try:
        with fitz.open(stream=pdf_bytes, filetype="pdf") as doc:
            for page_idx, page in enumerate(doc):
                # find_tables 는 페이지 단위. 강의계획서 주차표는 보통 한 페이지에 있음.
                try:
                    tabs = page.find_tables()
                except Exception as exc:
                    logger.warning("find_tables failed on page %d: %s", page_idx, exc)
                    continue

                tables = getattr(tabs, "tables", None) or list(tabs)
                for tab_idx, tab in enumerate(tables):
                    try:
                        rows: list[list[str | None]] = tab.extract()
                    except Exception as exc:
                        logger.warning("table.extract failed (p%d t%d): %s", page_idx, tab_idx, exc)
                        continue

                    weeks = _rows_to_weeks(rows)
                    if weeks is not None:
                        logger.info(
                            "extract_tables_from_pdf: matched page=%d table=%d weeks=%d",
                            page_idx, tab_idx, len(weeks),
                        )
                        return weeks
        logger.info("extract_tables_from_pdf: no usable table found — LLM fallback")
        return None
    except Exception as exc:
        # 표 추출은 best-effort. 어떤 예외든 fallback 으로.
        logger.warning("extract_tables_from_pdf: unexpected error (%s) — fallback", exc)
        return None


def _rows_to_weeks(rows: list[list[str | None]]) -> list[ParsedWeek] | None:
    """추출된 표 rows 가 강의계획서 주차표인지 판정하고 ParsedWeek list 로 변환.

    신뢰할 수 없으면 None 반환.
    """
    if not rows or len(rows) < _MIN_WEEK_ROWS + 1:  # 헤더 + 최소 데이터 행
        return None

    # 1. 헤더 행에서 컬럼 매핑 시도. 첫 행이 헤더가 아니면 처음 3행 중 가장 헤더다운 행 사용.
    header_idx, col_map = _find_header_row(rows[:3])
    if not col_map or "week" not in col_map or "topic" not in col_map:
        return None

    data_rows = rows[header_idx + 1:]
    if len(data_rows) < _MIN_WEEK_ROWS or len(data_rows) > _MAX_WEEK_ROWS:
        return None

    # 2. 데이터 행 → ParsedWeek
    weeks: list[ParsedWeek] = []
    for raw_row in data_rows:
        row = [(c or "").strip() for c in raw_row]
        if all(not c for c in row):
            continue  # 빈 행
        wk = _row_to_week(row, col_map)
        if wk is not None:
            weeks.append(wk)

    if len(weeks) < _MIN_WEEK_ROWS:
        return None

    # 3. 주차 번호 연속성 검사 — 비정상이면 잘못 잡힌 표.
    nums = [w.week_number for w in weeks]
    if min(nums) > 2:  # 1 또는 2부터 시작해야 정상
        return None
    span = max(nums) - min(nums) + 1
    if span > len(nums) * _CONSECUTIVE_TOLERANCE:
        # 예: 주차 [1, 2, 15] — 5주 분 표에 15주차가 끼면 의심
        return None

    return weeks


def _find_header_row(candidate_rows: list[list[str | None]]) -> tuple[int, dict[str, int]]:
    """후보 행 중 가장 헤더다운(=주차+주제 컬럼이 가장 많이 식별되는) 행을 찾는다."""
    best_idx = 0
    best_map: dict[str, int] = {}
    for i, row in enumerate(candidate_rows):
        m = _classify_columns([(c or "") for c in row])
        if len(m) > len(best_map):
            best_map = m
            best_idx = i
    return best_idx, best_map


def _classify_columns(header_cells: list[str]) -> dict[str, int]:
    """헤더 셀들을 보고 어떤 컬럼이 뭘 의미하는지 매핑.

    같은 의미 컬럼이 여러 개면 마지막 매칭을 사용 (강의계획서 표는 보통 비고 컬럼이 뒤에 있음).
    """
    mapping: dict[str, int] = {}
    for i, cell in enumerate(header_cells):
        c = cell.strip().lower()
        if not c:
            continue
        if any(h in c for h in _WEEK_COL_HINTS):
            mapping["week"] = i
        elif any(h in c for h in _DATE_COL_HINTS):
            mapping["date"] = i
        elif any(h in c for h in _TOPIC_COL_HINTS):
            mapping["topic"] = i
        elif any(h in c for h in _NOTE_COL_HINTS):
            mapping["notes"] = i
    return mapping


def _row_to_week(row: list[str], col_map: dict[str, int]) -> ParsedWeek | None:
    """한 데이터 행 → ParsedWeek. 주차 번호를 못 뽑으면 None."""
    week_idx = col_map.get("week")
    if week_idx is None or week_idx >= len(row):
        return None
    week_cell = row[week_idx]
    m = _WEEK_NUM_RE.search(week_cell)
    if not m:
        return None
    try:
        week_number = int(m.group(1))
    except ValueError:
        return None
    if not (1 <= week_number <= 30):
        return None

    topic = _safe_cell(row, col_map.get("topic"))
    notes_parts: list[str] = []
    # 비고 셀
    n = _safe_cell(row, col_map.get("notes"))
    if n:
        notes_parts.append(n)
    # 날짜 셀이 별도면 비고 앞에 붙여둠 — LLM 보조 정보 + recovery 입력
    d = _safe_cell(row, col_map.get("date"))
    if d and "date" in col_map and col_map["date"] != col_map.get("notes"):
        notes_parts.insert(0, f"[기간] {d}")

    notes = "\n".join(notes_parts) if notes_parts else None

    try:
        return ParsedWeek(
            week_number=week_number,
            topic=topic or None,
            notes=notes,
        )
    except Exception:
        return None


def _safe_cell(row: list[str], idx: int | None) -> str | None:
    if idx is None or idx >= len(row):
        return None
    val = row[idx].strip()
    return val or None
