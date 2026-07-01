"""강의계획서 텍스트 → 구조화 JSON 파서.

PyMuPDF로 추출한 강의계획서 원문 텍스트를 LLM으로 파싱하여
과목 메타데이터 + 주차별 일정 + 시험/과제 일정을 JSON으로 반환한다.

이 모듈의 가장 큰 실패 모드는 **표의 "비고" 한 셀에 여러 일정이 들어있을 때**
LLM이 그 중 한두 개만 뽑고 나머지를 누락하는 경우다.
프롬프트는 이 케이스를 명시적으로 다루도록 강화되어 있다.
"""

from __future__ import annotations

import asyncio
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
    ParsedWeek,
    SyllabusParseResult,
    SyllabusParseUsage,
)
from app.services import syllabus_cache
from app.services.pdf_text import clean_syllabus_text
from app.services.openai_client import get_async_openai
from app.services.structured_llm import run_structured_completion

logger = logging.getLogger(__name__)


MAX_INPUT_CHARS = 18000


# ---------- 교시(period) 표기 수업시간 파서 ----------
# 일부 강의계획서는 수업시간을 시각이 아니라 '교시' 번호로 적는다: "월2,3,4,화2,3,4,...".
# 이 경우 LLM 이 2,3,4 를 2시/3시/4시로 오해할 수 있어, 결정론적으로 교시→시각을 매핑한다.
# 연세대학교 기준: 1교시 09:00, 2교시 10:00, ... (교시 = 정각 시작 50분 수업).
# 학교마다 다르면 이 표만 조정하면 된다.
_PERIOD_START_HOUR = {p: p + 8 for p in range(1, 15)}  # 1→9, 2→10, ... 2교시=10:00
_DAY_KO_EN = {"월": "MON", "화": "TUE", "수": "WED", "목": "THU", "금": "FRI", "토": "SAT", "일": "SUN"}
# 요일 + 콤마로 이어진 교시 번호들. "월2,3,4" / "월 2, 3, 4" 모두 허용. 시각(콜론)은 매칭 안 함.
_PERIOD_LINE_RE = re.compile(r"([월화수목금토일])\s*((?:\d{1,2}\s*,?\s*)+)")


def parse_period_class_times(text: str) -> list[dict]:
    """'월2,3,4,화2,3,4,...' 처럼 요일+교시번호로 적힌 수업시간을 class_times dict 리스트로.

    각 요일의 교시들을 한 블록으로 합친다(연속 가정): 2,3,4교시 → 10:00~12:50.
    '수업시간'/'강의시간' 키워드 뒤 구간에서만 찾아 오탐을 줄인다. 패턴이 없으면 [].
    반환: [{"day":"MON","start_time":"10:00","end_time":"12:50"}, ...] (요일 순).
    """
    if not text:
        return []
    # '수업시간'/'강의시간' 이후 구간으로 한정. 없으면 전체에서 시도.
    region = text
    for key in ("수업시간", "강의시간"):
        i = text.find(key)
        if i != -1:
            region = text[i:i + 300]
            break

    day_periods: dict[str, set[int]] = {}
    for m in _PERIOD_LINE_RE.finditer(region):
        day = _DAY_KO_EN[m.group(1)]
        periods = [int(x) for x in re.findall(r"\d{1,2}", m.group(2))]
        periods = [p for p in periods if p in _PERIOD_START_HOUR]
        if periods:
            day_periods.setdefault(day, set()).update(periods)

    out: list[dict] = []
    for day in ("MON", "TUE", "WED", "THU", "FRI", "SAT", "SUN"):
        ps = sorted(day_periods.get(day, ()))
        if not ps:
            continue
        sh = _PERIOD_START_HOUR[ps[0]]
        eh = _PERIOD_START_HOUR[ps[-1]]
        out.append({"day": day, "start_time": f"{sh:02d}:00", "end_time": f"{eh:02d}:50"})
    return out


# ---------- 영어 요일범위+시간 파서 (예: "Mon-Thur (11:00 am~12:40 pm)") ----------
_EN_DAY = {"mon": "MON", "tue": "TUE", "wed": "WED", "thu": "THU", "fri": "FRI", "sat": "SAT", "sun": "SUN"}
_EN_ORDER = ["MON", "TUE", "WED", "THU", "FRI", "SAT", "SUN"]
_EN_DAY_TOKEN = r"(mon|tue|wed|thu|fri|sat|sun)[a-z]*"
# "Mon-Thur", "Mon - Fri", "Mon–Wed", "Mon~Thu" 등 요일 범위.
_EN_RANGE_RE = re.compile(_EN_DAY_TOKEN + r"\s*[-–~]\s*" + _EN_DAY_TOKEN, re.IGNORECASE)
_EN_TIME_RE = re.compile(r"(\d{1,2})\s*:\s*(\d{2})\s*(am|pm)?", re.IGNORECASE)


def _to_24h(h: int, m: int, ampm: str | None) -> str:
    ap = (ampm or "").lower()
    if ap == "pm" and h != 12:
        h += 12
    elif ap == "am" and h == 12:
        h = 0
    return f"{h:02d}:{m:02d}"


def parse_english_class_times(text: str) -> list[dict]:
    """'Mon-Thur (11:00 am~12:40 pm)' 처럼 영어 요일범위+시간을 class_times dict 리스트로.

    요일 범위(Mon-Thur → 월·화·수·목)를 **끝점만이 아니라 전부 펼쳐서** 반환한다.
    LLM 이 'Mon-Thur' 를 Mon·Thu 2개로 오해하는 문제를 결정론적으로 교정.
    'CLASS PERIOD'/'class time'/'수업시간' 근처로 범위를 한정해 오탐을 줄인다.
    """
    if not text:
        return []
    region = text
    low = text.lower()
    for key in ("class period", "class time", "class schedule", "수업시간", "강의시간", "lecture time"):
        i = low.find(key)
        if i != -1:
            region = text[i:i + 200]
            break

    m = _EN_RANGE_RE.search(region)
    if m:
        a = _EN_DAY[m.group(1)[:3].lower()]
        b = _EN_DAY[m.group(2)[:3].lower()]
        ia, ib = _EN_ORDER.index(a), _EN_ORDER.index(b)
        days = _EN_ORDER[ia:ib + 1] if ia <= ib else [a, b]
    else:
        # 범위가 아니면 나열된 요일들(Mon, Wed, Fri)을 순서대로 수집.
        seen = []
        for mm in re.finditer(_EN_DAY_TOKEN, region, re.IGNORECASE):
            d = _EN_DAY[mm.group(1)[:3].lower()]
            if d not in seen:
                seen.append(d)
        days = seen
    if not days:
        return []

    times = _EN_TIME_RE.findall(region)
    if len(times) < 2:
        return []
    start = _to_24h(int(times[0][0]), int(times[0][1]), times[0][2])
    end = _to_24h(int(times[1][0]), int(times[1][1]), times[1][2])
    return [{"day": d, "start_time": start, "end_time": end} for d in days]


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

(R4) **assignments 에는 과제의 마감일만 넣는다.** 출제일은 별도 assignments 원소로 만들지 마라
     (학생 입장에서 "출제"는 어색 — 사용자가 보는 캘린더 표기를 위함).
     - title 은 반드시 `과제 N 마감` 형태로 끝나야 한다 (또는 보고서/Report 등 명칭 + 마감).
     - 출제일이 함께 명시돼 있으면 description 에 "출제 M/D" 형식으로 보존한다.
     - 예) "6/12 (금) 과제 1 출제" + "6/19 (금) 과제 1 마감 23:59"
         → assignments 1개: title="과제 1 마감", due_date="2026-06-19", description="출제 6/12, 23:59 까지"
     - 출제일만 있고 마감일이 명시 안 됐으면 assignments 에 넣지 마라 (weeks.notes 에만 보존).
     - 마감일만 있고 출제일이 없으면 마감 하나만 넣고 description 은 null.
     - **'제출/Due/까지' 도 '마감'으로 간주**, 같은 키워드군이다.
     - title 에서 시험 키워드(중간/기말/퀴즈/쪽지) 와 헷갈리지 않게 — 평가는 exams, 제출물은 assignments 로 분리.

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
            {"title": "과제 1 마감", "due_date": "2026-06-19", "description": "출제 6/12, 23:59 까지"},
            {"title": "과제 2 마감", "due_date": "2026-06-30", "description": "출제 6/26, 23:59 까지"},
            {"title": "과제 3 마감", "due_date": "2026-07-10", "description": "출제 7/8"},
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


def _get_client() -> AsyncOpenAI:
    if not settings.OPENAI_API_KEY:
        raise SyllabusParseError("OPENAI_API_KEY is not configured")
    return get_async_openai()


async def parse_syllabus(
    text: str,
    year: int,
    term: str,
    *,
    prefilled_weeks: list[ParsedWeek] | None = None,
) -> SyllabusParseResult:
    """강의계획서 텍스트를 파싱하여 구조화 결과를 반환한다.

    파이프라인:
      1) clean_syllabus_text: 페이지 헤더/푸터 + 일정 이후 섹션 제거 (입력 토큰 ↓)
      2) Redis 캐시 hit 시 즉시 반환 (SYLLABUS_CACHE_ENABLED)
      3) OpenAI 호출:
         - prefilled_weeks 가 있으면 minimal 경로 (course+events만 LLM)
         - SYLLABUS_PARSE_PARALLEL=True: 단일 호출을 둘로 분할
         - 기본: 단일 호출
      4) _recover_missing_events: weeks.notes 기반 누락 회수
      5) 캐시 저장

    Args:
        prefilled_weeks: PyMuPDF 표 추출이 성공해서 미리 채워진 ParsedWeek list.
            제공 시 LLM 은 course meta + exams/assignments 만 추출하면 되므로
            출력 토큰이 크게 줄어들고 latency 절반 가까이 감소.

    Raises:
        SyllabusParseError: API 호출 실패, JSON 파싱 실패, 스키마 검증 실패.
    """
    cleaned = clean_syllabus_text(text).strip()
    if not cleaned:
        raise SyllabusParseError("Empty syllabus text")

    truncated = _truncate(cleaned)
    logger.info(
        "[PARSE] input cleaned: %d → %d chars (cleaner saved %d)",
        len(text), len(truncated), max(0, len(text) - len(truncated)),
    )

    # 캐시 조회 — 같은 (텍스트, 학기, prefilled 유무) 조합이 최근 파싱됐으면 즉시 반환.
    # prefilled 유무를 키에 포함해서 hybrid/full 결과가 섞이지 않게 한다.
    cache_key: str | None = None
    if settings.SYLLABUS_CACHE_ENABLED:
        cache_marker = f"hybrid_{len(prefilled_weeks)}" if prefilled_weeks else "full"
        cache_key = syllabus_cache.make_cache_key(truncated, year, f"{term}|{cache_marker}")
        cached = await syllabus_cache.get_cached(cache_key)
        if cached is not None:
            logger.info("[PARSE] cache HIT — saved OpenAI call entirely")
            return cached

    # OpenAI 호출 — prefilled weeks 가 있으면 minimal 호출 (가장 빠름)
    if prefilled_weeks:
        syllabus, usage = await _call_openai_with_prefilled(
            truncated, year, term, prefilled_weeks,
        )
    elif settings.SYLLABUS_PARSE_PARALLEL:
        syllabus, usage = await _call_openai_parallel(truncated, year, term)
    else:
        syllabus, usage = await _call_openai_single(truncated, year, term)

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

    result = SyllabusParseResult(syllabus=syllabus, usage=usage)

    # 캐시 저장 — 다음 같은 입력은 0초.
    if cache_key is not None:
        await syllabus_cache.set_cached(cache_key, result)

    return result


# prefilled_weeks 가 있을 때 사용하는 minimal 시스템 프롬프트.
# weeks 는 이미 PyMuPDF 표 추출로 채워졌으므로 LLM 에 요청하지 않는다.
# course meta + exams + assignments 만 추출 → 출력 토큰 50%+ 절약.
SYSTEM_PROMPT_MINIMAL = """당신은 한국 대학교 강의계획서(syllabus)의 일부 정보를 구조화 JSON으로 추출하는 파서입니다.
주차표는 이미 별도로 추출되어 입력에 포함되어 있습니다. 당신은 course 메타데이터와 시험/과제 일정만 추출하면 됩니다.

# 1. 추출 대상 (이 호출에서만)

- course: 과목명, 담당교수, 학점, 강의실, 정규 강의 시간(class_times), total_weeks
- exams:  중간/기말/쪽지시험/퀴즈/발표시험 등 평가 일정
- assignments: 보고서/과제의 **마감일** (출제일은 description 에 보존)
- weeks: 반드시 빈 배열 []. 주차 정보는 시스템이 별도로 채웁니다.

# 2. 절대 어기면 안 되는 규칙

(R1) 출력은 JSON 객체 1개. 다른 텍스트·코드펜스·주석 금지.

(R2) 한 셀/한 줄에 여러 일정이 적혀 있으면 모두 분리. "6/10 퀴즈 1 / 6/12 과제 1 출제" → 퀴즈는 exams, 과제 출제는 weeks.notes 에만 (assignments 아님).

(R3) **퀴즈/쪽지시험/미니테스트는 exams 에**, **과제 마감만 assignments 에**.
     title 예: "퀴즈 1", "중간고사", "과제 1 마감".

(R4) **assignments 에는 과제 마감일만 넣는다. 출제일은 별도 항목으로 만들지 마라.**
     - title 은 반드시 "과제 N 마감" 으로 끝나야 한다 (또는 보고서/Report 등 명칭 + 마감).
     - 같은 과제의 출제일이 함께 명시돼 있으면 description 에 "출제 M/D" 형식으로 보존한다.
     - 출제일만 있고 마감일이 없으면 assignments 에 넣지 마라.
     - '제출/Due/까지' 는 '마감'으로 간주.

(R5) 날짜는 학기 컨텍스트(연도/학기)로 절대 날짜화. "6/22" → "2026-06-22".

(R6) 추측 금지. 명시되지 않은 시간/위치/마감은 null.

(R7) 입력에 제공된 주차표(prefilled weeks)의 notes 안에도 시험/과제가 있다.
     반드시 그것도 exams/assignments 에 옮기고, weeks 자체는 빈 배열로 둔다.

(R8) confidence:
     - 모든 시험/퀴즈/과제 마감을 빠짐없이 추출했으면 0.85~1.0
     - 일부 누락 의심이면 0.5~0.75

# 3. 출력 JSON 스키마

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
  "weeks": [],
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


async def _call_openai_with_prefilled(
    truncated: str,
    year: int,
    term: str,
    prefilled_weeks: list[ParsedWeek],
) -> tuple[ParsedSyllabus, SyllabusParseUsage]:
    """표 추출로 weeks 가 이미 채워진 경로 — LLM은 course meta + 일정만 만든다.

    출력에서 weeks 가 빠지고 (1000+ 토큰 절감) few-shot 도 더 작은 걸 쓰므로
    입력/출력 양쪽 다 줄어 latency 가 큰 폭으로 감소.
    """
    # weeks 컨텍스트를 user prompt 에 압축해서 같이 제공.
    # notes 가 LLM의 exams/assignments 추출 단서가 된다.
    weeks_context = json.dumps(
        [
            {"w": w.week_number, "t": w.topic, "n": w.notes}
            for w in prefilled_weeks
        ],
        ensure_ascii=False,
    )

    term_label = {
        "1": "1학기", "2": "2학기",
        "summer": "여름 계절학기", "winter": "겨울 계절학기",
    }.get(term, term)

    user_prompt = (
        f"[학기 컨텍스트]\n연도: {year}\n학기: {term_label}\n\n"
        f"[강의계획서 원문]\n{truncated}\n\n"
        f"[이미 추출된 주차표 (참고용)]\n{weeks_context}\n\n"
        "위 정보로 course 메타와 시험/과제 일정만 JSON으로 채우시오. "
        "weeks 는 빈 배열로 두시오. "
        "주차표 notes 안에 적혀 있는 시험/퀴즈/과제 일정도 빠짐없이 exams/assignments 로 옮기시오."
    )

    client = _get_client()
    try:
        # Structured Outputs(strict json_schema) — 일정 자동등록 정확도가 중요한 경로.
        # 미지원·거부 시 자동 json_object 폴백(structured_llm 서킷 브레이커).
        response = await run_structured_completion(
            client,
            model=settings.OPENAI_SYLLABUS_MODEL,
            messages=[
                {"role": "system", "content": SYSTEM_PROMPT_MINIMAL},
                {"role": "user", "content": user_prompt},
            ],
            schema_model=ParsedSyllabus,
            schema_name="syllabus",
            max_tokens=settings.OPENAI_SYLLABUS_MAX_TOKENS,
            temperature=settings.OPENAI_SYLLABUS_TEMPERATURE,
        )
    except OpenAIError as exc:
        logger.exception("OpenAI syllabus (prefilled) parse failed")
        raise SyllabusParseError(f"OpenAI request failed: {exc}") from exc

    syllabus = _validate_response_content(response.choices[0].message.content)

    # LLM 이 weeks 를 비우라고 했어도 안 비우는 경우가 있음 → 강제로 prefilled 로 덮어쓴다.
    # (PyMuPDF 가 셀 경계 그대로 잡은 게 더 정확하다.)
    syllabus.weeks = list(prefilled_weeks)

    logger.info(
        "[PARSE_PREFILLED] weeks=%d (from PyMuPDF) exams=%d assignments=%d tokens=%d",
        len(syllabus.weeks), len(syllabus.exams), len(syllabus.assignments),
        _safe_tok(response, "total_tokens"),
    )
    return syllabus, _usage_from_response(response)


async def _call_openai_single(
    truncated: str,
    year: int,
    term: str,
) -> tuple[ParsedSyllabus, SyllabusParseUsage]:
    """기존 단일 호출 — 가장 안전한 경로."""
    user_prompt = _build_user_prompt(truncated, year, term)
    client = _get_client()

    try:
        # Structured Outputs + few-shot 병행 (few-shot 은 최종 응답 형식엔 영향 없이
        # "한 셀 다중 일정" 분리를 학습시키는 용도). 미지원·거부 시 json_object 폴백.
        response = await run_structured_completion(
            client,
            model=settings.OPENAI_SYLLABUS_MODEL,
            messages=[
                {"role": "system", "content": SYSTEM_PROMPT},
                # Few-shot: 한 셀에 여러 일정이 들어있는 케이스를 명시적으로 학습.
                {"role": "user", "content": FEWSHOT_USER},
                {"role": "assistant", "content": FEWSHOT_ASSISTANT},
                {"role": "user", "content": user_prompt},
            ],
            schema_model=ParsedSyllabus,
            schema_name="syllabus",
            max_tokens=settings.OPENAI_SYLLABUS_MAX_TOKENS,
            temperature=settings.OPENAI_SYLLABUS_TEMPERATURE,
        )
    except OpenAIError as exc:
        logger.exception("OpenAI syllabus parse failed")
        raise SyllabusParseError(f"OpenAI request failed: {exc}") from exc

    syllabus = _validate_response_content(response.choices[0].message.content)
    return syllabus, _usage_from_response(response)


# 병렬 호출 시 각 호출에 덧붙이는 지시. 같은 SYSTEM_PROMPT + FEWSHOT 을 공유하되
# user prompt 끝에서 출력 범위를 좁힌다. R1-R9 규칙은 SYSTEM_PROMPT 에서 이미 강제.
_PARALLEL_HINT_A = (
    "\n\n[이번 호출 한정 지시]\n"
    "- course 와 weeks 만 정확히 채우시오.\n"
    "- exams 와 assignments 는 반드시 빈 배열 [].\n"
    "- weeks.notes 에는 시험/퀴즈/과제 관련 원문을 빠짐없이 보존하시오 (별도 호출에서 활용)."
)
_PARALLEL_HINT_B = (
    "\n\n[이번 호출 한정 지시]\n"
    "- exams 와 assignments 만 정확히 채우시오. R3, R4 규칙을 엄수.\n"
    "- course 는 name 만 채우고 나머지는 null, class_times 빈 배열, total_weeks 는 16.\n"
    "- weeks 는 반드시 빈 배열 []."
)


async def _call_openai_parallel(
    truncated: str,
    year: int,
    term: str,
) -> tuple[ParsedSyllabus, SyllabusParseUsage]:
    """호출을 둘로 쪼개 asyncio.gather 로 병렬 실행.

    A: course + weeks (notes 에 원문 보존)
    B: exams + assignments + confidence + warnings

    출력 토큰을 분산해 latency = max(A, B) 가 된다. 두 호출이 같은 입력을 보지만
    서로의 결과를 모르므로 작은 불일치 가능성 있음 — recovery 가 안전망 역할.
    """
    user_prompt_base = _build_user_prompt(truncated, year, term)
    client = _get_client()

    async def call(extra_hint: str):
        # strict 스키마에서도 모든 필드가 required 라 빈 배열([])로 채워지므로
        # "exams/assignments 는 [] 로" 같은 분할 힌트와 충돌하지 않는다.
        return await run_structured_completion(
            client,
            model=settings.OPENAI_SYLLABUS_MODEL,
            messages=[
                {"role": "system", "content": SYSTEM_PROMPT},
                {"role": "user", "content": FEWSHOT_USER},
                {"role": "assistant", "content": FEWSHOT_ASSISTANT},
                {"role": "user", "content": user_prompt_base + extra_hint},
            ],
            schema_model=ParsedSyllabus,
            schema_name="syllabus",
            max_tokens=settings.OPENAI_SYLLABUS_MAX_TOKENS,
            temperature=settings.OPENAI_SYLLABUS_TEMPERATURE,
        )

    try:
        resp_a, resp_b = await asyncio.gather(
            call(_PARALLEL_HINT_A),
            call(_PARALLEL_HINT_B),
        )
    except OpenAIError as exc:
        logger.exception("OpenAI syllabus parallel parse failed")
        raise SyllabusParseError(f"OpenAI request failed: {exc}") from exc

    syl_a = _validate_response_content(resp_a.choices[0].message.content)
    syl_b = _validate_response_content(resp_b.choices[0].message.content)

    # 병합 — course/weeks 는 A, exams/assignments 는 B. confidence 는 둘 중 낮은 쪽.
    merged = ParsedSyllabus(
        course=syl_a.course,
        weeks=syl_a.weeks,
        exams=syl_b.exams,
        assignments=syl_b.assignments,
        confidence=min(syl_a.confidence, syl_b.confidence),
        warnings=list(dict.fromkeys(syl_a.warnings + syl_b.warnings)),  # 순서 보존 dedup
    )

    merged_usage = SyllabusParseUsage(
        model=resp_a.model,
        prompt_tokens=_safe_tok(resp_a, "prompt_tokens") + _safe_tok(resp_b, "prompt_tokens"),
        completion_tokens=_safe_tok(resp_a, "completion_tokens") + _safe_tok(resp_b, "completion_tokens"),
        total_tokens=_safe_tok(resp_a, "total_tokens") + _safe_tok(resp_b, "total_tokens"),
    )

    logger.info(
        "[PARSE_PARALLEL] A(weeks=%d) + B(exams=%d, assignments=%d), tokens total=%d",
        len(merged.weeks), len(merged.exams), len(merged.assignments), merged_usage.total_tokens,
    )
    return merged, merged_usage


def _validate_response_content(raw: str | None) -> ParsedSyllabus:
    """OpenAI 응답 content → ParsedSyllabus 검증. JSON 파싱/스키마 양쪽 다 여기서."""
    raw = raw or ""
    try:
        payload: Any = json.loads(raw)
    except json.JSONDecodeError as exc:
        logger.error("Syllabus parser returned non-JSON: %s", raw[:500])
        raise SyllabusParseError("Model returned invalid JSON") from exc
    try:
        return ParsedSyllabus.model_validate(payload)
    except ValidationError as exc:
        logger.error("Syllabus schema validation failed: %s", exc)
        raise SyllabusParseError(f"Schema validation failed: {exc}") from exc


def _usage_from_response(response) -> SyllabusParseUsage:
    return SyllabusParseUsage(
        model=response.model,
        prompt_tokens=_safe_tok(response, "prompt_tokens"),
        completion_tokens=_safe_tok(response, "completion_tokens"),
        total_tokens=_safe_tok(response, "total_tokens"),
    )


def _safe_tok(response, attr: str) -> int:
    """response.usage 가 None 일 때 0 으로 안전 처리."""
    usage = getattr(response, "usage", None)
    if usage is None:
        return 0
    return getattr(usage, attr, 0) or 0


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
    # 줄바꿈/세미콜론/'및'/'/' 로 1차 split.
    # 단, 숫자 사이의 '/'(예: '6/22')는 날짜 구분자이므로 split 하지 않는다 —
    # 이 슬래시까지 쪼개면 _extract_first_date 가 M/D 날짜를 못 읽어 누락 회수가 무력화된다.
    parts = re.split(r"[\n;]|\s및\s|(?<!\d)[／/](?!\d)", notes)
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
    """제목 정규화 일치만으로 중복 판정. 같은 날 다른 종류의 시험(예: 퀴즈+중간)이
    함께 적혀 있으면 둘 다 보존해야 한다."""
    title_norm = re.sub(r"\s+", "", title_hint).lower()
    for e in syllabus.exams:
        if e.exam_date == d and re.sub(r"\s+", "", e.title).lower() == title_norm:
            return True
    return False


def _already_has_assignment(syllabus: ParsedSyllabus, title_hint: str, d: date) -> bool:
    """제목 정규화 일치만으로 중복 판정. 같은 날짜라도 다른 과제(과제1 마감 + 과제2 출제 등)는
    별개로 보존한다."""
    title_norm = re.sub(r"\s+", "", title_hint).lower()
    for a in syllabus.assignments:
        a_norm = re.sub(r"\s+", "", a.title).lower()
        if a.due_date == d and a_norm == title_norm:
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

            # 과제 마감만 회수한다. 출제일만 있는 세그먼트는 캘린더에 항목으로 만들지 않는다
            # (학생 입장에서 "출제"는 어색 — weeks.notes 에는 이미 원문이 보존됨).
            if has_assign_kw and has_due:
                base = _assignment_base_title(seg)
                title = f"{base} 마감"
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
            # 과제 출제만 있는 케이스 — assignment 만들지 않고 통과 (weeks.notes 에 이미 보존됨).
            if has_assign_kw and has_issue:
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
