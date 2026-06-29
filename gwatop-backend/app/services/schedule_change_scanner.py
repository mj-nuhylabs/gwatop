"""강의자료(material) 텍스트에서 시험/과제 '일정 변경' 공지를 스캔한다.

강의계획서가 정한 일정이 학기 중 강의자료(공지 슬라이드 등)로 바뀌는 경우가 잦다.
강의자료를 분류할 때 텍스트에 일정/날짜/변경 신호가 있으면 LLM 으로 변경사항을 추출해
호출자(file_tasks._scan_and_apply_schedule_changes)가 기존 schedules 의 날짜를 갱신하거나
명확히 날짜가 적힌 신규 시험/과제를 추가한다.

보수적 정책:
- LLM 호출 전 키워드 게이트로 비용/오탐을 최소화한다(대부분의 강의자료는 일정 공지가 없다).
- 명확한 날짜가 있는 변경/신규만 추출. 추측 금지(없으면 빈 배열).
"""

from __future__ import annotations

import json
import logging

from openai import AsyncOpenAI

from app.core.config import settings

logger = logging.getLogger(__name__)

# 입력 토큰 상한 — 공지는 보통 앞부분이라 앞 8000자만 본다(비용/지연 제한).
_MAX_CHARS = 8000

# 키워드 게이트 — 시험/과제 마커 ∩ (날짜 or 변경 마커) 둘 다 있을 때만 LLM 호출.
_EVENT_MARKERS = (
    "시험", "고사", "중간", "기말", "퀴즈", "quiz", "exam", "midterm", "final",
    "과제", "assignment", "발표", "프로젝트", "제출", "마감", "due", "homework", "hw",
)
_DATE_CHANGE_MARKERS = (
    "변경", "연기", "조정", "순연", "앞당", "미뤄", "미룸", "일정", "날짜", "일자",
    "공지", "안내", "월", "일", "date", "reschedul", "postpone", "delay", "moved",
    "changed", "update", "announc", "/", "-",
)


def material_mentions_schedule(text: str | None) -> bool:
    """LLM 을 부를 가치가 있는지 싸게 판정. 시험/과제 마커와 날짜/변경 마커가 둘 다 있어야 True."""
    if not text:
        return False
    low = text.lower()
    has_event = any(k in low for k in _EVENT_MARKERS)
    has_date = any(k in low for k in _DATE_CHANGE_MARKERS)
    return has_event and has_date


class ScheduleChangeError(Exception):
    """일정 변경 스캔 실패(LLM 호출/파싱 오류)."""


_client: AsyncOpenAI | None = None


def _get_client() -> AsyncOpenAI:
    global _client
    if _client is None:
        if not settings.OPENAI_API_KEY:
            raise ScheduleChangeError("OPENAI_API_KEY is not configured")
        _client = AsyncOpenAI(api_key=settings.OPENAI_API_KEY)
    return _client


_SYSTEM_PROMPT = """\
너는 대학 강의자료(슬라이드/공지)에서 '시험·과제 일정 변경 또는 신규 일정' 공지만 정확히 뽑아내는 도우미다.
주어진 텍스트에 명확한 날짜가 적힌 일정 변경/신규 공지가 있을 때만 보고한다. 추측·창작 금지.

규칙:
- existing_schedules 에 있는 일정의 날짜/시간/장소가 바뀌었다는 공지면 "updates" 에 넣고,
  반드시 그 일정의 정확한 title 을 existing_title 로 적는다(목록에 없는 제목이면 update 가 아니다).
- 목록에 없는, 날짜가 명확한 새 시험/퀴즈/과제 공지면 "new_events" 에 넣는다.
- 날짜가 불명확하거나 단순 수업 내용이면 아무것도 넣지 마라(빈 배열).
- 날짜는 반드시 YYYY-MM-DD. 연도가 안 적혀 있으면 context_year 를 사용한다.
- 시간은 HH:MM(24시간) 또는 생략.
- type 은 "exam"(시험/퀴즈/고사) 또는 "assignment"(과제/제출/프로젝트).

오직 아래 JSON 만 출력:
{"updates":[{"existing_title":"...","type":"exam|assignment","new_date":"YYYY-MM-DD","new_start_time":"HH:MM(optional)","new_location":"(optional)","note":"무엇이 어떻게 바뀌었는지 한 줄"}],
 "new_events":[{"title":"...","type":"exam|assignment","date":"YYYY-MM-DD","start_time":"HH:MM(optional)","location":"(optional)","note":"한 줄"}]}
"""


async def scan_schedule_changes(
    *,
    text: str,
    existing: list[dict],
    context_year: int | None,
) -> dict:
    """강의자료 텍스트 → {"updates": [...], "new_events": [...]}.

    existing: [{"title","type","date"(YYYY-MM-DD)}] 형태의 현재 일정 목록(LLM 매칭 힌트).
    실패 시 ScheduleChangeError.
    """
    snippet = (text or "")[:_MAX_CHARS]
    payload = {
        "context_year": context_year,
        "existing_schedules": existing,
        "material_text": snippet,
    }
    try:
        client = _get_client()
        resp = await client.chat.completions.create(
            model=settings.OPENAI_SYLLABUS_MODEL,
            temperature=0.0,
            max_tokens=1024,
            response_format={"type": "json_object"},
            messages=[
                {"role": "system", "content": _SYSTEM_PROMPT},
                {"role": "user", "content": json.dumps(payload, ensure_ascii=False)},
            ],
        )
        content = resp.choices[0].message.content or "{}"
        data = json.loads(content)
    except Exception as exc:  # OpenAI / JSON 오류 모두 도메인 예외로
        raise ScheduleChangeError(str(exc)) from exc

    updates = data.get("updates") or []
    new_events = data.get("new_events") or []
    if not isinstance(updates, list):
        updates = []
    if not isinstance(new_events, list):
        new_events = []
    return {"updates": updates, "new_events": new_events}
