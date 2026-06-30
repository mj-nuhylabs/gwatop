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


def has_change_signal(text: str | None) -> bool:
    """본문에 변경 관련 표현이 하나라도 있으면 True. LLM 호출 게이트로 사용."""
    if not text:
        return False
    low = text.lower()
    return any(kw.lower() in low for kw in _CHANGE_KEYWORDS)


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

ChangeField = Literal["class_time", "classroom", "assignment_due"]


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


_SYSTEM = """당신은 학습자료 본문에서 '강의계획서를 갱신해야 할 변경'만 찾아내는 도구입니다.
JSON 객체 하나만 출력합니다. 규칙:
- "변경/연기/이동/공지/정정/취소/휴강/보강" 등 명시적 변경 표현이 있을 때만 후보로 삼는다.
- 단순히 날짜·시간·장소가 적혀 있다는 이유만으로 변경으로 보지 않는다(원래 일정 안내일 수 있음).
- 강의계획서에 저장된 현재 값과 *달라진* 것만 후보로 만든다. 같으면 무시한다.
- 각 후보는 반드시 evidence(변경을 명시한 원문, 15단어 이내)를 포함한다.
- field 는 "class_time"(강의시간) | "classroom"(강의실) | "assignment_due"(과제/시험 마감) 중 하나.
- assignment_due 면 target_title 에 어떤 과제/시험인지 제목을 적는다(현재 목록의 제목과 최대한 일치).
출력 스키마: {"updates": [{"field","target_title","old_value","new_value","evidence","confidence"}]}
변경이 없으면 updates 는 빈 배열."""


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
        # 값이 실제로 달라졌는지 최종 가드(LLM 이 같은 값을 후보로 낼 때 방지).
        if (u.old_value or "").strip() and u.old_value.strip() == u.new_value.strip():
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
