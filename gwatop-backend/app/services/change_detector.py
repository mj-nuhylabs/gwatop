"""변경 탐지 (Stage 3) — 학습자료에서 강의계획서 갱신 후보를 찾는다.

원칙:
  1) **키워드 게이트** — 본문에 '변경/연기/이동/공지/정정' 류 명시적 변경 표현이 없으면
     LLM 을 아예 호출하지 않고 종료한다 (값싼 사전 필터).
  2) 표현이 있을 때만 LLM 1회 호출로 변경 후보를 구조화 추출한다. 강의계획서에 저장된
     현재 값(강의시간/강의실/과제마감)과 대조해 *바뀐 것만* 후보로 만든다.
  3) 반드시 근거 원문(evidence)을 포함한다. 단순히 날짜가 적혀 있다는 이유만으로는
     변경으로 보지 않는다.

자동 반영은 절대 하지 않는다 — 후보(updates)를 반환할 뿐, DB 갱신은 사용자 승인 후
라우트(approve)에서 수행한다. 이 모듈은 파싱 헬퍼(apply 시 문자열→구조)도 함께 제공한다.
"""

from __future__ import annotations

import json
import logging
import re
from dataclasses import dataclass
from datetime import datetime
from typing import Literal, Sequence

from openai import OpenAIError
from pydantic import BaseModel, ValidationError

from app.core.config import settings
from app.services.openai_client import get_async_openai
from app.services.structured_llm import structured_chat_json

logger = logging.getLogger(__name__)


# ---------- 키워드 게이트 (LLM 없음) ----------

_CHANGE_KEYWORDS = [
    "변경", "변동", "바뀌", "바뀐", "바뀜", "수정", "정정", "조정",
    "연기", "순연", "미뤄", "미룸", "앞당", "당겨", "이동", "옮겨", "옮김",
    "공지", "안내드", "취소", "휴강", "보강", "변경됩니다", "변경되었",
    "reschedul", "postpone", "delay", "moved", "change", "cancel", "rescheduled",
]

# 새 과제/제출물 공지 신호 — 강의자료에 마감과 함께 새 과제가 뜨는 케이스를 게이트에 포함.
# (없으면 '과제 7/5 제출' 처럼 '변경' 단어가 없는 새 과제 공지를 놓친다.)
_ASSIGNMENT_KEYWORDS = [
    "과제", "숙제", "제출", "마감", "레포트", "리포트", "보고서", "기한",
    "deadline", "submit", "homework", "assignment", "tarea",
]


def has_change_signal(text: str | None) -> bool:
    """본문에 변경 또는 새 과제 관련 표현이 하나라도 있으면 True. LLM 호출 게이트로 사용."""
    if not text:
        return False
    low = text.lower()
    return any(kw.lower() in low for kw in _CHANGE_KEYWORDS) or any(
        kw.lower() in low for kw in _ASSIGNMENT_KEYWORDS
    )


def _relevant_excerpt(text: str) -> str:
    """변경 키워드 주변 + 앞부분을 합쳐 LLM 입력을 줄인다.

    전체를 보내면 토큰이 커지므로, 키워드가 등장한 줄들을 모아 보내되 상한을 둔다.
    키워드 줄이 부족하면 앞부분으로 보강한다.
    """
    limit = settings.CHANGE_DETECTION_INPUT_CHARS
    lines = text.splitlines()
    hit_lines = [ln for ln in lines if has_change_signal(ln)]
    excerpt = "\n".join(hit_lines).strip()
    if len(excerpt) < limit // 2:
        # 키워드 줄이 적으면 앞부분도 함께 (공지가 표 형태로 흩어진 경우 대비).
        excerpt = (excerpt + "\n\n" + text[:limit]).strip()
    return excerpt[:limit]


# ---------- LLM 변경 탐지 ----------

ChangeField = Literal["class_time", "classroom", "assignment_due", "new_assignment"]


class _ProposedUpdate(BaseModel):
    field: ChangeField
    target_title: str | None   # assignment_due 일 때 대상 과제/시험 제목, 그 외 null
    old_value: str | None
    new_value: str
    evidence: str              # 변경을 명시한 원문(짧게)
    confidence: float


class _ChangeResult(BaseModel):
    updates: list[_ProposedUpdate]


@dataclass(frozen=True)
class ChangeContext:
    class_time: str           # 현재 강의시간 (사람이 읽는 문자열)
    location: str | None      # 현재 강의실
    assignments: list[tuple[str, str]]  # [(제목, 마감 ISO), ...]


_SYSTEM = """당신은 학습자료 본문에서 '강의 일정에 반영할 항목'을 찾아내는 도구입니다.
JSON 객체 하나만 출력합니다. 두 종류를 구분합니다.

[1] 새 과제 (field="new_assignment")
- 현재 '과제/시험 마감' 목록에 **없던 새 과제/숙제/제출물**이 **마감일과 함께** 공지된 경우.
- target_title = 과제 이름(짧게, 예: "예비과 과제", "1과 과제", "발음 과제"). 이름이 없으면 "과제".
- new_value = 마감일 원문 그대로(예: "7월 5일", "2026-07-05", "7/5"). old_value = null.
- ⚠️ '연습문제', '예시', 수업 중 활동, 교재 페이지처럼 **제출 마감이 없는 것은 제외**.
- 이미 현재 목록에 같은 과제가 있으면(중복) 내지 않는다.

[2] 기존 항목 변경 (field="class_time" | "classroom" | "assignment_due")
- 이미 있는 강의시간/강의실/과제·시험 마감이 **바뀐** 경우에만.
- "변경/연기/이동/정정/취소/휴강/보강" 등 명시적 변경 표현이 있을 때만.
- 강의계획서에 저장된 현재 값과 *달라진* 것만. 같으면 무시.
- assignment_due 면 target_title 은 현재 목록의 제목과 최대한 일치시킨다.
- ⚠️ 새 과제를 억지로 기존 시험/과제의 날짜 변경(assignment_due)으로 만들지 마라 —
  현재 목록에 없는 것은 반드시 new_assignment 로 분류한다.

공통 규칙:
- 각 항목은 반드시 evidence(근거 원문, 15단어 이내) 포함.
- 확실하지 않으면 넣지 않는다.
출력 스키마: {"updates": [{"field","target_title","old_value","new_value","evidence","confidence"}]}
해당 없으면 updates 는 빈 배열."""


async def detect_changes(text: str, ctx: ChangeContext) -> list[_ProposedUpdate]:
    """변경 후보 리스트를 반환. 키워드 게이트는 호출자가 이미 통과시킨 것으로 가정.

    LLM/파싱 실패 시 빈 리스트(안전 — 후보 0개).
    """
    excerpt = _relevant_excerpt(text)
    if not excerpt.strip():
        return []

    assignments_str = (
        "\n".join(f"- {t} (마감 {due})" for t, due in ctx.assignments) or "(없음)"
    )
    user = (
        "강의계획서에 저장된 현재 값\n"
        f"- 강의시간: {ctx.class_time or '(없음)'}\n"
        f"- 강의실: {ctx.location or '(없음)'}\n"
        f"- 과제/시험 마감:\n{assignments_str}\n\n"
        f"학습자료 본문(변경 관련 부분):\n{excerpt}"
    )
    try:
        raw, _m, _t, _f = await structured_chat_json(
            get_async_openai(),
            model=settings.CHANGE_DETECTION_MODEL,
            system=_SYSTEM,
            user=user,
            schema_model=_ChangeResult,
            schema_name="change_updates",
            max_tokens=700,
            temperature=0,
        )
        result = _ChangeResult.model_validate(json.loads(raw))
    except (OpenAIError, json.JSONDecodeError, ValidationError) as exc:
        logger.warning("detect_changes 실패: %s — 후보 없음 처리", exc)
        return []

    out: list[_ProposedUpdate] = []
    for u in result.updates:
        if u.confidence < settings.CHANGE_DETECTION_MIN_CONFIDENCE:
            continue
        if not (u.new_value or "").strip() or not (u.evidence or "").strip():
            continue
        # 과제마감 변경인데 대상 과제명이 없으면 어떤 일정을 고칠지 특정할 수 없어 승인 불가 →
        # 애초에 후보로 만들지 않는다(노이즈 방지).
        if u.field == "assignment_due" and not (u.target_title or "").strip():
            continue
        # 새 과제도 캘린더/과제탭에 표시하려면 이름이 있어야 한다.
        if u.field == "new_assignment" and not (u.target_title or "").strip():
            continue
        # 값이 실제로 달라졌는지 최종 가드(LLM 이 같은 값을 후보로 낼 때 방지).
        # new_assignment 는 old_value 가 없으므로 이 가드 제외.
        if (
            u.field != "new_assignment"
            and (u.old_value or "").strip()
            and u.old_value.strip() == u.new_value.strip()
        ):
            continue
        out.append(u)
    return out


# ---------- apply 헬퍼 (승인 시 문자열 → 구조) ----------

_DAY_KO = {"월": "MON", "화": "TUE", "수": "WED", "목": "THU", "금": "FRI", "토": "SAT", "일": "SUN"}
_TIME_RE = re.compile(r"(\d{1,2})\s*:\s*(\d{2})")
_DATE_ISO_RE = re.compile(r"(\d{4})[-./](\d{1,2})[-./](\d{1,2})")
_DATE_KO_RE = re.compile(r"(\d{1,2})\s*월\s*(\d{1,2})\s*일")
_DATE_MD_RE = re.compile(r"\b(\d{1,2})[./](\d{1,2})\b")


def parse_class_time(new_value: str) -> dict | None:
    """'월 14:00-15:30' → {'day':'MON','start_time':'14:00','end_time':'15:30'}.

    요일/시작/종료를 모두 못 뽑으면 None.
    """
    if not new_value:
        return None
    day = None
    for ko, en in _DAY_KO.items():
        if ko in new_value:
            day = en
            break
    times = _TIME_RE.findall(new_value)
    if day is None or len(times) < 2:
        return None
    start = f"{int(times[0][0]):02d}:{times[0][1]}"
    end = f"{int(times[1][0]):02d}:{times[1][1]}"
    return {"day": day, "start_time": start, "end_time": end}


def parse_due_date(new_value: str, fallback_year: int) -> datetime | None:
    """'2025-04-15', '4월 15일 18:00', '4/15' → datetime.

    연도가 없으면 fallback_year(보통 기존 일정의 연도)를 쓴다. 시각이 없으면 23:59.
    파싱 실패 시 None.
    """
    if not new_value:
        return None
    year = month = day = None
    m = _DATE_ISO_RE.search(new_value)
    if m:
        year, month, day = int(m.group(1)), int(m.group(2)), int(m.group(3))
    else:
        m = _DATE_KO_RE.search(new_value)
        if m:
            month, day = int(m.group(1)), int(m.group(2))
        else:
            m = _DATE_MD_RE.search(new_value)
            if m:
                month, day = int(m.group(1)), int(m.group(2))
    if month is None or day is None:
        return None
    if year is None:
        year = fallback_year
    tm = _TIME_RE.search(new_value)
    hour, minute = (int(tm.group(1)), int(tm.group(2))) if tm else (23, 59)
    try:
        return datetime(year, month, day, hour, minute)
    except ValueError:
        return None
