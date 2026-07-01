"""추출 신호 + doc_type 분류를 **단일 LLM 호출**로 통합한다 (Stage 1).

기존엔 doc_type 판정(1단어)과 과목명 추정이 별도 LLM 호출이라 워스트 케이스에서
순차 2~3 왕복이 났다. 이 모듈은 한 번의 Structured Outputs 호출로
  (1) 행정 구조 신호(평가비율/주차일정/운영정책/교재목록) +
  (2) 과목 신원(과목명/코드/교수/학기) + subject_keywords +
  (3) doc_type + confidence + evidence(reason)
를 한꺼번에 채운다. 내용이 아니라 문서의 *기능·구조*로 판단하는 게 정확도의 핵심이다.

속도 원칙:
  - 빠른 모델(nano) 우선 → confidence < 임계 또는 '불확실' 일 때만 큰 모델(mini)로 1회 승급.
  - 입력은 앞부분만(CLASSIFY_DOC_INPUT_CHARS) — 강의계획서 신호는 앞쪽에 몰려 있음.
  - 콘텐츠 해시 dedup — 같은 파일 재업로드면 LLM 호출 없이 캐시 재사용.
  - 정적 system 프롬프트를 맨 앞에 둬 OpenAI 자동 프롬프트 캐싱 prefix 를 탄다.

이 모듈은 순수 판정 로직 — DB I/O 는 호출자(Celery 태스크)가 한다.
호출 전 값싼 휴리스틱(auto_classifier.detect_kind_heuristic) 으로 명백한 케이스를
먼저 걸러 LLM 자체를 건너뛰는 것은 호출자 책임이다.
"""

from __future__ import annotations

import hashlib
import json
import logging
from dataclasses import dataclass
from typing import Any, Literal

from openai import OpenAIError
from pydantic import BaseModel, ValidationError

from app.core.config import settings
from app.services.openai_client import get_async_openai
from app.services.structured_llm import structured_chat_json

logger = logging.getLogger(__name__)


# ---------- Structured Outputs 스키마 ----------

DocType = Literal["강의계획서", "학습자료", "불확실"]


class DocSignals(BaseModel):
    """단일 호출로 채우는 구조 신호 + 분류 결과."""

    course_name_guess: str | None
    course_code: str | None
    professor: str | None
    semester: str | None

    has_grading_breakdown: bool
    has_weekly_schedule: bool
    has_course_policy: bool
    has_textbook_list: bool
    is_subject_content: bool
    subject_keywords: list[str]

    doc_type: DocType
    confidence: float
    reason: str


_SYSTEM_PROMPT = """당신은 대학 강의 문서를 분석하는 빠른 분류 도구입니다.
파일명과 본문(앞부분 일부일 수 있음)을 보고, 한 번의 응답으로 정보 추출과 유형 분류를
동시에 수행하세요. 설명·서론·마크다운 없이 JSON 객체 하나만 출력합니다.

먼저 아래 신호를 채운 뒤, 그 신호를 근거로 doc_type 을 결정하세요.
- course_name_guess: 추정 과목명(예: 미적분학). 없으면 null
- course_code: 학수번호. 없으면 null
- professor: 담당 교수명. 없으면 null
- semester: 학기(예: 2025-2학기). 없으면 null
- has_grading_breakdown: 성적/평가 비율표가 있으면 true (예: 중간 30%, 기말 40%)
- has_weekly_schedule: 1주차~N주차 형태의 주차별 일정이 있으면 true
- has_course_policy: 출결/지각/표절 등 운영 정책이 있으면 true
- has_textbook_list: 교재/참고문헌 목록이 있으면 true
- is_subject_content: 과목 내용 자체(개념·공식·풀이·예제)가 본문의 핵심이면 true
- subject_keywords: 본문 핵심 주제 키워드 3~5개
- doc_type: "강의계획서" | "학습자료" | "불확실"
- confidence: 0~1 사이 숫자
- reason: 어떤 신호를 근거로 판단했는지 한 문장

[분류 규칙]
- 강의계획서: 행정 구조 신호(평가비율·주차일정·운영정책·교재목록)가 2개 이상.
  특히 평가비율 + 주차일정이 함께 있으면 거의 확정.
- 학습자료: is_subject_content 가 핵심이고 행정 구조가 거의 없음.
  (슬라이드 첫 장에 과목 정보가 있다고 강의계획서가 아니다 — 평가비율 + 주차별 일정 같은
   행정 구조가 있어야 계획서다.)
- 불확실: 신호가 섞여 있거나 근거 부족. 억지로 결정하지 말 것."""


@dataclass(frozen=True)
class DocClassification:
    kind: Literal["syllabus", "material"]  # 내부 분기용
    doc_type: DocType                       # 원본 LLM 판정
    confidence: float
    signals: DocSignals
    needs_review: bool                      # 저신뢰/불확실 — 사용자 확인 권장
    used_model: str
    escalated: bool
    cached: bool
    reason: str


def _user_prompt(filename: str, text: str) -> str:
    truncated = (text or "")[: settings.CLASSIFY_DOC_INPUT_CHARS]
    return f"파일명: {filename}\n\n본문:\n{truncated}"


async def _call_model(model: str, filename: str, text: str) -> DocSignals | None:
    """한 모델로 1회 호출. 파싱/오류 시 None 반환(상위에서 폴백/승급 처리)."""
    try:
        raw, _resp_model, _tokens, _finish = await structured_chat_json(
            get_async_openai(),
            model=model,
            system=_SYSTEM_PROMPT,
            user=_user_prompt(filename, text),
            schema_model=DocSignals,
            schema_name="doc_signals",
            max_tokens=400,
            temperature=0,
        )
    except OpenAIError as exc:
        logger.warning("doc_classifier: LLM 호출 실패 model=%s: %s", model, exc)
        return None
    try:
        return DocSignals.model_validate(json.loads(raw))
    except (json.JSONDecodeError, ValidationError) as exc:
        logger.warning("doc_classifier: JSON 파싱 실패 model=%s: %s", model, exc)
        return None


def _kind_of(doc_type: DocType) -> Literal["syllabus", "material"]:
    # '불확실' 은 안전하게 material 로 흘려 일단 막히지 않게 하되 needs_review 로 표시한다.
    return "syllabus" if doc_type == "강의계획서" else "material"


async def classify_document(text: str, filename: str) -> DocClassification:
    """통합 분류 진입점 — 빠른 모델 우선, 저신뢰 시 큰 모델로 1회 승급.

    캐시 → 빠른 모델 → (저신뢰면) 큰 모델 순. 모든 LLM 실패 시 '불확실/needs_review'.
    """
    cache_key = _cache_key(filename, text)
    cached = await _cache_get(cache_key)
    if cached is not None:
        return cached

    fast = settings.CLASSIFY_FAST_MODEL
    big = settings.CLASSIFY_ESCALATE_MODEL

    sig = await _call_model(fast, filename, text)
    used_model, escalated = fast, False

    # 승급 조건: 빠른 모델이 실패했거나 / 불확실 / 저신뢰.
    need_escalate = (
        sig is None
        or sig.doc_type == "불확실"
        or sig.confidence < settings.CLASSIFY_CONFIDENCE_THRESHOLD
    )
    if need_escalate and big != fast:
        sig2 = await _call_model(big, filename, text)
        if sig2 is not None:
            sig, used_model, escalated = sig2, big, True

    if sig is None:
        # 두 모델 다 실패 — 막히지 않게 material 로 흘리되 확인 필요로 표시.
        result = DocClassification(
            kind="material",
            doc_type="불확실",
            confidence=0.0,
            signals=_empty_signals(),
            needs_review=True,
            used_model=used_model,
            escalated=escalated,
            cached=False,
            reason="LLM 분류 실패 — 기본 material 로 처리",
        )
        return result  # 실패 결과는 캐시하지 않는다(다음 시도에 회복 가능).

    needs_review = (
        sig.doc_type == "불확실"
        or sig.confidence < settings.CLASSIFY_REVIEW_THRESHOLD
    )
    result = DocClassification(
        kind=_kind_of(sig.doc_type),
        doc_type=sig.doc_type,
        confidence=sig.confidence,
        signals=sig,
        needs_review=needs_review,
        used_model=used_model,
        escalated=escalated,
        cached=False,
        reason=sig.reason,
    )
    await _cache_set(cache_key, result)
    return result


# 휴리스틱 confidence 가 이 값 이상이면 LLM 없이 그 결정을 신뢰한다(가장 빠른 경로).
# 그 미만(애매 구간) 이거나 detect_kind_heuristic 이 None 이면 통합 LLM 분류로 넘어간다.
# auto_classifier.detect_kind_heuristic 의 의도된 confidence 티어(강한신호 1+보조 3 → 0.80,
# 약한신호 material → 0.85, 파일명 마커 → 0.95)와 정렬: None(진짜 애매)만 LLM 으로 보낸다.
_HEURISTIC_TRUST = 0.80


# 파일명에 이게 있으면 '실라버스' 판정을 휴리스틱만으로 신뢰한다(그 외엔 LLM 검증).
_SYLLABUS_FILENAME_MARKERS = ("syllabus", "강의계획서", "실라버스", "course outline", "수업계획서")


async def decide_document_kind(text: str, filename: str) -> DocClassification:
    """공개 진입점 — 값싼 휴리스틱 우선, 애매할 때만 통합 LLM 분류.

    - 휴리스틱의 **학습자료** 판정은 신뢰(흔한 경우, 오탐 위험 낮음).
    - 휴리스틱의 **강의계획서** 판정은 *파일명 마커*가 있을 때만 신뢰한다. 내용 키워드만으로
      강의계획서라 본 경우(예: '강의계획서·평가·주차'를 언급하는 오리엔테이션 슬라이드)엔
      LLM 으로 구조(평가비율+주차일정 폼)를 검증해 강의 슬라이드가 실라버스로 새는 걸 막는다.
    - 텍스트가 비어 LLM 이 무의미하면 휴리스틱 결과를 그대로 신뢰.
    - 그 외에는 classify_document (빠른모델→필요시 큰모델) 1회.
    """
    # 지연 import — auto_classifier 가 이 모듈을 import 하지 않으므로 순환 없음.
    from app.services.auto_classifier import detect_kind_heuristic

    h = detect_kind_heuristic(text, filename)
    if h is not None:
        no_text = not (text or "").strip()
        fn_marker = any(k in filename.lower() for k in _SYLLABUS_FILENAME_MARKERS)
        trust = (
            no_text
            or (h.kind == "material" and h.confidence >= _HEURISTIC_TRUST)
            or (h.kind == "syllabus" and fn_marker)
        )
        if trust:
            return DocClassification(
                kind=h.kind,
                doc_type="강의계획서" if h.kind == "syllabus" else "학습자료",
                confidence=h.confidence,
                signals=_empty_signals(),
                needs_review=False,
                used_model="heuristic",
                escalated=False,
                cached=False,
                reason=h.reason,
            )
    return await classify_document(text, filename)


def _empty_signals() -> DocSignals:
    return DocSignals(
        course_name_guess=None, course_code=None, professor=None, semester=None,
        has_grading_breakdown=False, has_weekly_schedule=False,
        has_course_policy=False, has_textbook_list=False,
        is_subject_content=False, subject_keywords=[],
        doc_type="불확실", confidence=0.0, reason="",
    )


# ---------- 콘텐츠 해시 dedup (Redis, silent miss) ----------

_CACHE_PREFIX = "docclass:v1:"
_redis_client: Any | None = None
_redis_unavailable = False


def _get_redis():
    global _redis_client, _redis_unavailable
    if _redis_unavailable or not settings.CLASSIFY_CACHE_ENABLED:
        return None
    if _redis_client is not None:
        return _redis_client
    try:
        from redis import asyncio as aioredis  # type: ignore[import-not-found]
        _redis_client = aioredis.from_url(
            settings.REDIS_URL,
            encoding="utf-8",
            decode_responses=True,
            socket_connect_timeout=2,
            socket_timeout=2,
        )
        return _redis_client
    except Exception as exc:  # noqa: BLE001
        logger.warning("doc_classifier: redis init 실패 (%s) — 캐시 비활성", exc)
        _redis_unavailable = True
        return None


def _cache_key(filename: str, text: str) -> str:
    h = hashlib.sha256()
    h.update((filename or "").encode("utf-8"))
    h.update(b"\x00")
    # 분류 입력으로 실제 보는 앞부분만 해시 — 뒷부분이 달라도 분류는 같으므로 캐시 적중률↑.
    h.update((text or "")[: settings.CLASSIFY_DOC_INPUT_CHARS].encode("utf-8"))
    return _CACHE_PREFIX + h.hexdigest()


async def _cache_get(cache_key: str) -> DocClassification | None:
    client = _get_redis()
    if client is None:
        return None
    try:
        payload = await client.get(cache_key)
    except Exception as exc:  # noqa: BLE001
        logger.warning("doc_classifier: 캐시 GET 실패 (%s) — miss 처리", exc)
        return None
    if not payload:
        return None
    try:
        data = json.loads(payload)
        sig = DocSignals.model_validate(data["signals"])
        return DocClassification(
            kind=data["kind"], doc_type=data["doc_type"], confidence=data["confidence"],
            signals=sig, needs_review=data["needs_review"],
            used_model=data["used_model"], escalated=data["escalated"],
            cached=True, reason=data.get("reason", ""),
        )
    except Exception as exc:  # noqa: BLE001 — 스키마 바뀐 엔트리는 무시.
        logger.warning("doc_classifier: stale 캐시 (%s) — 무시", exc)
        return None


async def _cache_set(cache_key: str, result: DocClassification) -> None:
    client = _get_redis()
    if client is None:
        return
    try:
        payload = json.dumps({
            "kind": result.kind,
            "doc_type": result.doc_type,
            "confidence": result.confidence,
            "signals": result.signals.model_dump(),
            "needs_review": result.needs_review,
            "used_model": result.used_model,
            "escalated": result.escalated,
            "reason": result.reason,
        }, ensure_ascii=False)
        await client.setex(cache_key, settings.CLASSIFY_CACHE_TTL_SECONDS, payload)
    except Exception as exc:  # noqa: BLE001
        logger.warning("doc_classifier: 캐시 SET 실패 (%s) — 쓰기 skip", exc)
