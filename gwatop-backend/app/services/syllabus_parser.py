"""강의계획서 텍스트 → 구조화 JSON 파서.

PyMuPDF로 추출한 강의계획서 원문 텍스트를 LLM으로 파싱하여
과목 메타데이터 + 주차별 일정 + 시험/과제 일정을 JSON으로 반환한다.

이 모듈의 가장 큰 실패 모드는 **표의 "비고" 한 셀에 여러 일정이 들어있을 때**
LLM이 그 중 한두 개만 뽑고 나머지를 누락하는 경우다.
프롬프트는 이 케이스를 명시적으로 다루도록 강화되어 있다.
"""

from __future__ import annotations

import json
import logging
import re
from datetime import date
from typing import Any

from openai import AsyncOpenAI, OpenAIError
from pydantic import ValidationError

from app.core.config import settings
from app.schemas.syllabus import (
    ParsedAssignment,
    ParsedExam,
    ParsedSyllabus,
    SyllabusParseResult,
    SyllabusParseUsage,
)

logger = logging.getLogger(__name__)


MAX_INPUT_CHARS = 18000


SYSTEM_PROMPT = """당신은 한국 대학교 강의계획서(syllabus)를 구조화 JSON으로 변환하는 전문 파서입니다.
입력은 PDF에서 추출된 평문 텍스트이며 표 셀 경계가 무너지거나 줄바꿈이 어긋나 있을 수 있습니다.

# 1. 추출 대상

- course: 과목명, 담당교수, 학점, 강의실, 정규 강의 시간(class_times), total_weeks
- weeks:  각 주차의 week_number, topic, notes (그 셀 원문 거의 그대로)
- exams:  중간고사, 기말고사, 쪽지시험, **퀴즈(Quiz)**, 발표시험 등 평가가 일어나는 일정 전부
- assignments: 보고서/과제의 **마감일(Due / 제출 / 마감)** 일정 전부

# 2. 절대 어기면 안 되는 규칙

(R1) 출력은 JSON 객체 1개. 다른 텍스트·코드펜스·주석 절대 금지.

(R2) **한 셀에 여러 일정이 적혀 있으면 모두 분리하여 추출한다.**
     비고/주차 셀 안에 줄바꿈, 콤마, 세미콜론, "및", "/", 점(·) 으로 항목이 나뉘어 있으면
     각 항목을 별도 exams/assignments 원소로 추가한다. 절대 묶지 마라.
     예) "6/10 (수) 퀴즈 1\\n6/12 (금) 과제 1 출제"
         → exams 에 "퀴즈 1" 1개, weeks.notes에 "과제 1 출제" 기록 (출제만으론 assignments 안 만든다).

(R3) **퀴즈/쪽지시험/미니테스트는 모두 exams 에 넣는다.** (assignments 아님)
     title 예: "퀴즈 1", "쪽지시험 2", "중간고사", "기말고사"
     평가 시간이 'HH:MM~HH:MM' 또는 'HH:MM-HH:MM' 으로 명시되면 start_time/end_time 둘 다 채운다.

(R4) **과제의 출제일과 마감일은 각각 별개의 assignments 원소로 추출한다.** 묶지 마라.
     - title 은 반드시 `과제 N 출제` 또는 `과제 N 마감` 형태로 끝나야 한다 (또는 보고서/Report 등 명칭 + 출제/마감).
       사용자가 캘린더에서 한 줄 텍스트만 봐도 둘을 즉시 구분할 수 있어야 한다.
     - "과제 1 출제" → assignments: title="과제 1 출제", due_date=출제일, description=null
     - "과제 1 마감 23:59" → assignments: title="과제 1 마감", due_date=마감일, description="23:59"
     - 출제일만 있고 마감일이 명시 안 됐어도 출제일 하나는 assignments 에 넣는다 (마감 항목은 만들지 마라).
     - 마감일만 있고 출제일이 없으면 마감 하나만 넣는다.
     - **'제출/Due/까지' 도 '마감'으로 간주**, 같은 키워드군이다.
     - title에서 시험 키워드(중간/기말/퀴즈/쪽지) 와 헷갈리지 않게 — 평가는 exams, 제출물은 assignments 로 분리.

(R5) 날짜는 학기 컨텍스트(연도/학기)로 절대 날짜화한다.
     - "6/22 (월)" → "2026-06-22"
     - "주차 행 날짜 범위 6/1 ~ 6/5" 는 그 주의 시작 날짜를 weeks 의 참고 정보로 이해.
       단 별도 exams/assignments 의 정확한 날짜가 셀 안에 있으면 그것을 우선한다.

(R6) **추측 금지.** 셀에 명시되지 않은 시간/위치/마감은 null. 학기 컨텍스트에서 유추할 수 있는
     절대 날짜는 예외(R5).

(R7) ★, ☆, ※, ▶ 같은 강조 기호가 붙은 일정은 더 중요한 신호이므로 절대 빠뜨리지 마라.

(R8) confidence:
     - 핵심 필드 + 모든 시험·퀴즈·과제 마감을 빠짐없이 추출했다고 자신하면 0.85~1.0
     - 일부 누락 의심이면 0.5~0.75
     - 강의계획서 형식이 아니거나 매우 깨졌으면 0.3 이하

(R9) warnings 에는 "원문에 있는 시험/과제처럼 보이는데 위 규칙 때문에 일정으로 못 옮긴 항목"
     의 원문 스니펫을 짧게 기록한다. 비어 있어도 된다.

# 3. 출력 JSON 스키마 (정확히 이 구조)

{
  "course": {
    "name": string,
    "professor": string|null,
    "credit": integer|null,
    "location": string|null,
    "class_times": [
      {"day": "MON"|"TUE"|"WED"|"THU"|"FRI"|"SAT"|"SUN", "start_time": "HH:MM", "end_time": "HH:MM"}
    ],
    "total_weeks": integer
  },
  "weeks": [
    {"week_number": integer, "topic": string|null, "notes": string|null}
  ],
  "exams": [
    {"title": string, "exam_date": "YYYY-MM-DD"|null, "start_time": "HH:MM"|null,
     "end_time": "HH:MM"|null, "location": string|null, "description": string|null}
  ],
  "assignments": [
    {"title": string, "due_date": "YYYY-MM-DD"|null, "description": string|null}
  ],
  "confidence": number,
  "warnings": [string]
}
"""


# Few-shot — 사용자가 자주 마주치는 "한 셀 다중 일정" 케이스를 명시적으로 학습시킨다.
FEWSHOT_USER = """[학기 컨텍스트]
연도: 2026
학기: 여름 계절학기

[강의계획서 원문]
과목명: 자료구조 (예시)
담당교수: 홍길동
정규 강의: 월수 10:00-12:00, 강의실 공학관 401

6. 주차별 강의 일정

| 주차 | 날짜       | 강의 주제                          | 비고 |
| 1주차 | 6/1 ~ 6/5  | 강의 소개, 알고리즘 분석, 빅오 표기법 | - |
| 2주차 | 6/8 ~ 6/12 | 배열, 연결리스트, 스택, 큐         | 6/10 (수) 퀴즈 1
6/12 (금) 과제 1 출제 |
| 3주차 | 6/15 ~ 6/19 | 재귀, 정렬 알고리즘 (버블/선택/삽입) | 6/19 (금) 과제 1 마감 23:59 |
| 4주차 | 6/22 ~ 6/26 | 중간고사 및 고급 정렬 (병합/퀵)    | ★ 6/22 (월) 중간고사 10:00~12:00
6/26 (금) 과제 2 출제 |
| 5주차 | 6/29 ~ 7/3 | 이진 탐색 트리, 균형 트리, 힙      | 6/30 (화) 23:59 과제 2 마감
7/3 (금) 퀴즈 2 |
| 6주차 | 7/6 ~ 7/10 | 해시 테이블, 그래프 표현, BFS/DFS  | 7/8 (수) 과제 3 출제
7/10 (금) 과제 3 마감 |
| 7주차 | 7/13 ~ 7/17 | 최단경로, 동적 계획법, 기말고사    | 7/15 (수) 퀴즈 3
★ 7/17 (금) 기말고사 10:00~12:00 |

위 강의계획서를 시스템 프롬프트의 스키마에 맞춰 JSON으로 파싱하시오."""


FEWSHOT_ASSISTANT = json.dumps(
    {
        "course": {
            "name": "자료구조 (예시)",
            "professor": "홍길동",
            "credit": None,
            "location": "공학관 401",
            "class_times": [
                {"day": "MON", "start_time": "10:00", "end_time": "12:00"},
                {"day": "WED", "start_time": "10:00", "end_time": "12:00"},
            ],
            "total_weeks": 7,
        },
        "weeks": [
            {"week_number": 1, "topic": "강의 소개, 알고리즘 분석, 빅오 표기법", "notes": None},
            {"week_number": 2, "topic": "배열, 연결리스트, 스택, 큐",
             "notes": "6/10 (수) 퀴즈 1; 6/12 (금) 과제 1 출제"},
            {"week_number": 3, "topic": "재귀, 정렬 알고리즘 (버블/선택/삽입)",
             "notes": "6/19 (금) 과제 1 마감 23:59"},
            {"week_number": 4, "topic": "중간고사 및 고급 정렬 (병합/퀵)",
             "notes": "★ 6/22 (월) 중간고사 10:00~12:00; 6/26 (금) 과제 2 출제"},
            {"week_number": 5, "topic": "이진 탐색 트리, 균형 트리, 힙",
             "notes": "6/30 (화) 23:59 과제 2 마감; 7/3 (금) 퀴즈 2"},
            {"week_number": 6, "topic": "해시 테이블, 그래프 표현, BFS/DFS",
             "notes": "7/8 (수) 과제 3 출제; 7/10 (금) 과제 3 마감"},
            {"week_number": 7, "topic": "최단경로, 동적 계획법, 기말고사",
             "notes": "7/15 (수) 퀴즈 3; ★ 7/17 (금) 기말고사 10:00~12:00"},
        ],
        "exams": [
            {"title": "퀴즈 1", "exam_date": "2026-06-10", "start_time": None, "end_time": None,
             "location": None, "description": None},
            {"title": "중간고사", "exam_date": "2026-06-22", "start_time": "10:00", "end_time": "12:00",
             "location": None, "description": None},
            {"title": "퀴즈 2", "exam_date": "2026-07-03", "start_time": None, "end_time": None,
             "location": None, "description": None},
            {"title": "퀴즈 3", "exam_date": "2026-07-15", "start_time": None, "end_time": None,
             "location": None, "description": None},
            {"title": "기말고사", "exam_date": "2026-07-17", "start_time": "10:00", "end_time": "12:00",
             "location": None, "description": None},
        ],
        "assignments": [
            {"title": "과제 1 출제", "due_date": "2026-06-12", "description": None},
            {"title": "과제 1 마감", "due_date": "2026-06-19", "description": "23:59"},
            {"title": "과제 2 출제", "due_date": "2026-06-26", "description": None},
            {"title": "과제 2 마감", "due_date": "2026-06-30", "description": "23:59"},
            {"title": "과제 3 출제", "due_date": "2026-07-08", "description": None},
            {"title": "과제 3 마감", "due_date": "2026-07-10", "description": None},
        ],
        "confidence": 0.95,
        "warnings": [],
    },
    ensure_ascii=False,
)


def _build_user_prompt(text: str, year: int, term: str) -> str:
    term_label = {
        "1": "1학기", "2": "2학기",
        "summer": "여름 계절학기", "winter": "겨울 계절학기",
    }.get(term, term)

    return (
        f"[학기 컨텍스트]\n연도: {year}\n학기: {term_label}\n\n"
        f"[강의계획서 원문]\n{text}\n\n"
        "위 강의계획서를 시스템 프롬프트의 스키마에 맞춰 JSON으로 파싱하시오. "
        "한 셀에 여러 일정이 있으면 모두 분리해서 추출하라."
    )


def _truncate(text: str, limit: int = MAX_INPUT_CHARS) -> str:
    if len(text) <= limit:
        return text
    head = text[: limit - 500]
    tail = text[-500:]
    return f"{head}\n... [중략: 입력이 너무 길어 일부 생략됨] ...\n{tail}"


class SyllabusParseError(Exception):
    pass


_client: AsyncOpenAI | None = None


def _get_client() -> AsyncOpenAI:
    global _client
    if _client is None:
        if not settings.OPENAI_API_KEY:
            raise SyllabusParseError("OPENAI_API_KEY is not configured")
        _client = AsyncOpenAI(api_key=settings.OPENAI_API_KEY)
    return _client


async def parse_syllabus(
    text: str,
    year: int,
    term: str,
) -> SyllabusParseResult:
    """강의계획서 텍스트를 파싱하여 구조화 결과를 반환한다.

    Raises:
        SyllabusParseError: API 호출 실패, JSON 파싱 실패, 스키마 검증 실패.
    """
    cleaned = text.strip()
    if not cleaned:
        raise SyllabusParseError("Empty syllabus text")

    user_prompt = _build_user_prompt(_truncate(cleaned), year, term)
    client = _get_client()

    try:
        response = await client.chat.completions.create(
            model=settings.OPENAI_SYLLABUS_MODEL,
            temperature=settings.OPENAI_SYLLABUS_TEMPERATURE,
            max_tokens=settings.OPENAI_SYLLABUS_MAX_TOKENS,
            response_format={"type": "json_object"},
            messages=[
                {"role": "system", "content": SYSTEM_PROMPT},
                # Few-shot: 한 셀에 여러 일정이 들어있는 케이스를 명시적으로 학습.
                {"role": "user", "content": FEWSHOT_USER},
                {"role": "assistant", "content": FEWSHOT_ASSISTANT},
                {"role": "user", "content": user_prompt},
            ],
        )
    except OpenAIError as exc:
        logger.exception("OpenAI syllabus parse failed")
        raise SyllabusParseError(f"OpenAI request failed: {exc}") from exc

    raw = response.choices[0].message.content or ""
    try:
        payload: Any = json.loads(raw)
    except json.JSONDecodeError as exc:
        logger.error("Syllabus parser returned non-JSON: %s", raw[:500])
        raise SyllabusParseError("Model returned invalid JSON") from exc

    try:
        syllabus = ParsedSyllabus.model_validate(payload)
    except ValidationError as exc:
        logger.error("Syllabus schema validation failed: %s", exc)
        raise SyllabusParseError(f"Schema validation failed: {exc}") from exc

    # 누락 보완: weeks.notes 안에 시험/과제 키워드+날짜가 있는데 exams/assignments에
    # 옮겨지지 않은 항목이 있으면 정규식으로 회수한다.
    added_exams, added_assignments, leftovers = _recover_missing_events(syllabus, year)
    if added_exams or added_assignments:
        logger.info(
            "[PARSE_RECOVERY] exams +%d, assignments +%d (GPT가 놓친 항목 보완)",
            len(added_exams), len(added_assignments),
        )
        syllabus.exams.extend(added_exams)
        syllabus.assignments.extend(added_assignments)
    if leftovers:
        syllabus.warnings.extend(leftovers)

    usage = SyllabusParseUsage(
        model=response.model,
        prompt_tokens=response.usage.prompt_tokens if response.usage else 0,
        completion_tokens=response.usage.completion_tokens if response.usage else 0,
        total_tokens=response.usage.total_tokens if response.usage else 0,
    )

    return SyllabusParseResult(syllabus=syllabus, usage=usage)


# ---------- 누락 일정 회수 (정규식 후처리) ----------

# 6/22, 6/22(월), 06/22, 2026-06-22, 2026.06.22 등을 흡수.
_DATE_RE = re.compile(
    r"""
    (?:                                   # 1) YYYY-MM-DD or YYYY.MM.DD
        (?P<y1>20\d{2})[\.\-/](?P<m1>\d{1,2})[\.\-/](?P<d1>\d{1,2})
    )
    |
    (?:                                   # 2) M/D 또는 M월 D일 (연도는 컨텍스트에서)
        (?P<m2>\d{1,2})\s*[/월]\s*(?P<d2>\d{1,2})\s*일?
    )
    """,
    re.VERBOSE,
)

_TIME_RANGE_RE = re.compile(
    r"(\d{1,2}):(\d{2})\s*[~\-–]\s*(\d{1,2}):(\d{2})"
)
_TIME_SINGLE_RE = re.compile(r"(\d{1,2}):(\d{2})")

# 시험·퀴즈 키워드 — exams 후보
_EXAM_KEYWORDS = ["중간고사", "기말고사", "쪽지시험", "쪽지", "퀴즈", "quiz", "발표시험", "미니테스트"]
# 과제 마감 — assignments 후보 (반드시 마감/제출/Due 가 같이 있어야 함)
_DUE_KEYWORDS = ["마감", "제출", "Due", "due", "까지"]
_ISSUE_KEYWORDS = ["출제", "Out", "issue", "공지"]
_ASSIGN_KEYWORDS = ["과제", "보고서", "Report", "report", "Assignment", "assignment"]


def _split_segments(notes: str) -> list[str]:
    """비고 셀 텍스트를 여러 일정 후보로 분리한다."""
    # 줄바꿈/세미콜론/'및'/'/' 로 1차 split. 너무 짧은 조각은 합쳐서 본다.
    parts = re.split(r"[\n;／/]|\s및\s", notes)
    return [p.strip() for p in parts if p and p.strip()]


def _extract_first_date(text: str, year_hint: int) -> date | None:
    m = _DATE_RE.search(text)
    if not m:
        return None
    try:
        if m.group("y1"):
            return date(int(m.group("y1")), int(m.group("m1")), int(m.group("d1")))
        return date(year_hint, int(m.group("m2")), int(m.group("d2")))
    except ValueError:
        return None


def _extract_time_range(text: str) -> tuple[str | None, str | None]:
    m = _TIME_RANGE_RE.search(text)
    if m:
        h1, m1, h2, m2 = m.groups()
        return (f"{int(h1):02d}:{m1}", f"{int(h2):02d}:{m2}")
    m = _TIME_SINGLE_RE.search(text)
    if m:
        h, mm = m.groups()
        return (f"{int(h):02d}:{mm}", None)
    return (None, None)


def _already_has_exam(syllabus: ParsedSyllabus, title_hint: str, d: date) -> bool:
    title_norm = re.sub(r"\s+", "", title_hint).lower()
    for e in syllabus.exams:
        if e.exam_date == d and re.sub(r"\s+", "", e.title).lower() == title_norm:
            return True
        # title이 약간 달라도 같은 날짜의 시험이 이미 있다면 중복으로 간주
        if e.exam_date == d:
            return True
    return False


def _already_has_assignment(syllabus: ParsedSyllabus, title_hint: str, d: date) -> bool:
    title_norm = re.sub(r"\s+", "", title_hint).lower()
    for a in syllabus.assignments:
        a_norm = re.sub(r"\s+", "", a.title).lower()
        if a.due_date == d and a_norm == title_norm:
            return True
        # 같은 날짜 + 같은 종류(출제 vs 마감)의 과제가 이미 있으면 중복 — 한쪽 키워드만 일치해도 동일 취급
        if a.due_date == d:
            same_kind = (
                ("출제" in title_hint and "출제" in a.title)
                or ("마감" in title_hint and "마감" in a.title)
            )
            if same_kind:
                return True
    return False


def _exam_title_from_segment(seg: str) -> str:
    """세그먼트 텍스트에서 시험 종류를 추출. '퀴즈 1', '중간고사' 등."""
    lower = seg.lower()
    for kw in _EXAM_KEYWORDS:
        if kw.lower() in lower:
            # "퀴즈 1", "중간고사" 처럼 키워드 + 뒤따르는 숫자/식별자가 있으면 함께 포함
            m = re.search(rf"({re.escape(kw)}\s*\d*[가-힣A-Za-z]*)", seg, re.IGNORECASE)
            if m:
                return m.group(1).strip()
            return kw
    return "시험"


def _assignment_base_title(seg: str) -> str:
    """세그먼트에서 '과제 N', '보고서 N' 같은 기본 제목 추출. 접미어(출제/마감)는 별도로 붙인다."""
    for kw in _ASSIGN_KEYWORDS:
        m = re.search(rf"({re.escape(kw)}\s*\d*)", seg, re.IGNORECASE)
        if m:
            return m.group(1).strip()
    return "과제"


def _recover_missing_events(
    syllabus: ParsedSyllabus,
    year_hint: int,
) -> tuple[list[ParsedExam], list[ParsedAssignment], list[str]]:
    """GPT 출력의 weeks.notes 를 다시 훑어, exams/assignments 에 빠진 일정을 회수한다."""
    new_exams: list[ParsedExam] = []
    new_assignments: list[ParsedAssignment] = []
    leftovers: list[str] = []

    for w in syllabus.weeks:
        if not w.notes:
            continue
        for seg in _split_segments(w.notes):
            d = _extract_first_date(seg, year_hint)
            if d is None:
                continue
            seg_lower = seg.lower()

            is_exam_seg = any(kw.lower() in seg_lower for kw in _EXAM_KEYWORDS)
            has_due = any(kw in seg or kw.lower() in seg_lower for kw in _DUE_KEYWORDS)
            has_issue = any(kw in seg or kw.lower() in seg_lower for kw in _ISSUE_KEYWORDS)
            has_assign_kw = any(kw in seg or kw.lower() in seg_lower for kw in _ASSIGN_KEYWORDS)

            if is_exam_seg:
                title = _exam_title_from_segment(seg)
                if _already_has_exam(syllabus, title, d):
                    continue
                start_t, end_t = _extract_time_range(seg)
                try:
                    new_exams.append(
                        ParsedExam(
                            title=title,
                            exam_date=d,
                            start_time=_parse_hhmm(start_t),
                            end_time=_parse_hhmm(end_t),
                            location=None,
                            description=f"원문: {seg}"[:200],
                        )
                    )
                except ValidationError:
                    leftovers.append(seg[:160])
                continue

            # 과제 출제·마감을 각각 별개 항목으로 회수.
            if has_assign_kw and (has_due or has_issue):
                base = _assignment_base_title(seg)
                # 한 세그먼트에 출제·마감이 같이 적혀있는 경우는 드물지만, 키워드 둘 다 있으면
                # 보수적으로 마감만 만들고(출제일은 description으로 보존) GPT가 따로 처리하게 둔다.
                suffix = "마감" if has_due else "출제"
                title = f"{base} {suffix}"
                if not _already_has_assignment(syllabus, title, d):
                    try:
                        new_assignments.append(
                            ParsedAssignment(
                                title=title,
                                due_date=d,
                                description=f"원문: {seg}"[:200],
                            )
                        )
                    except ValidationError:
                        leftovers.append(seg[:160])
                continue

            # 시험·과제 키워드는 없지만 날짜 + ★ 같은 신호가 있는 모호한 항목 → warning
            if "★" in seg or "☆" in seg:
                leftovers.append(seg[:160])

    return new_exams, new_assignments, leftovers


def _parse_hhmm(value: str | None):
    if not value:
        return None
    try:
        h, m = value.split(":")
        from datetime import time as _time
        return _time(int(h), int(m))
    except (ValueError, AttributeError):
        return None
