"""파일 업로드 후처리 Celery 파이프라인.

extract_text_task:
    files.s3_key 다운로드 → (PDF면) PyMuPDF로 텍스트 추출 → files.extracted_text 저장.
    is_syllabus=True 이면 parse_syllabus_task, 아니면 classify_file_task 트리거.

parse_syllabus_task:
    files.extracted_text + course/semester 컨텍스트 → GPT-4o-mini 파싱 →
    schedules 테이블에 시험/과제 일정 자동 INSERT.
    + Day 4: 주차별 토픽을 Course.weekly_topics 에 저장하고 임베딩 캐시를 만든다.

classify_file_task (Day 4):
    files.filename + extracted_text + Course.weekly_topic_embeddings →
    파일명 regex / 임베딩 코사인 유사도 결합으로 주차 자동 배정.

notify_classified_task (Day 4 / Day 7 APNs placeholder):
    분류 완료 알림 — 지금은 로그만, Day 7에서 APNs로 교체.
"""

from __future__ import annotations

import asyncio
import difflib
import json
import logging
import re
from datetime import datetime, timedelta
from uuid import UUID

from sqlalchemy import select, delete
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from app.core import metrics
from app.core.database import make_celery_session_factory
from app.models.course import Course
from app.models.file import File
from app.models.schedule import Schedule
from app.models.semester import Semester
from app.models.syllabus_update_proposal import SyllabusUpdateProposal
from app.models.todo import Todo
from app.models.user import User
from app.schemas.syllabus import ParsedAssignment, ParsedExam, ParsedSyllabus, ParsedWeek
from app.core.config import settings
from app.services import s3
from app.services.classification import classify_file
from app.services.embedding_classifier import (
    EmbeddingClassifierError,
    build_weekly_topic_embeddings,
    deserialize_week_embeddings,
    serialize_week_embeddings,
)
from app.services.auto_classifier import (
    guess_course_identity_from_text,
    guess_course_name_from_filename,
)
from app.services.doc_classifier import (
    DocClassification,
    classify_document,
    decide_document_kind,
)
from app.services.change_detector import (
    ChangeContext,
    detect_changes,
    has_change_signal,
    parse_due_date,
)
from app.services.course_matcher import CourseMatchError, match_or_create_course
from app.services.doc_text import extract_text_from_docx_bytes, extract_text_from_pptx_bytes
from app.services.pdf_text import (
    extract_markdown_from_pdf_bytes,
    extract_tables_from_pdf,
    extract_text_from_pdf_bytes,
)
from app.services.syllabus_parser import (
    SyllabusParseError,
    parse_english_class_times,
    parse_period_class_times,
    parse_syllabus,
)
from app.services.todo_generator import build_auto_todos, build_undated_todo
from app.tasks.celery_app import celery_app

logger = logging.getLogger(__name__)


async def _commit_or_skip_duplicate(session) -> bool:
    """commit 하고, (file_id, content_type, scope) 유니크 충돌이면 rollback 후 False 반환.

    동시 워커가 같은 AIContent 조합을 먼저 저장한 race 를 흡수한다. 유니크 제약이
    아직 없는 환경(마이그레이션 미적용)에선 IntegrityError 가 안 나므로 기존 동작과 동일.
    """
    try:
        await session.commit()
        return True
    except IntegrityError:
        await session.rollback()
        logger.info("AIContent 중복 저장 race — 다른 워커가 먼저 저장함, skip")
        return False


# ---------- Celery entry points ----------

def _run_with_fresh_engine(coro_factory):
    """Celery 태스크에서 async 코드 실행 — 매번 새 engine으로 dispose까지 책임진다."""
    async def runner():
        engine, SessionLocal = make_celery_session_factory()
        try:
            await coro_factory(SessionLocal)
        finally:
            await engine.dispose()
    asyncio.run(runner())


@celery_app.task(name="tasks.extract_text")
def extract_text_task(file_id: str) -> None:
    _run_with_fresh_engine(lambda Session: _run_extract(file_id, Session))


@celery_app.task(name="tasks.parse_syllabus")
def parse_syllabus_task(file_id: str) -> None:
    _run_with_fresh_engine(lambda Session: _run_parse_syllabus(file_id, Session))


@celery_app.task(name="tasks.classify_file")
def classify_file_task(file_id: str) -> None:
    _run_with_fresh_engine(lambda Session: _run_classify(file_id, Session))


@celery_app.task(name="tasks.detect_changes")
def detect_changes_task(file_id: str) -> None:
    """학습자료 본문의 변경 공지를 탐지해 강의계획서 갱신 후보(제안)를 만든다.

    키워드 게이트를 통과한 파일에 대해서만 큐잉된다(빈 호출 방지). 자동 반영 없음 —
    pending 제안만 생성하고, 사용자 승인 시 라우트에서 DB 에 반영한다.
    """
    _run_with_fresh_engine(lambda Session: _run_detect_changes(file_id, Session))


@celery_app.task(name="tasks.dispatch_material")
def dispatch_material_task(file_id: str) -> None:
    """needs_review 파일을 사용자가 '학습자료'로 확정했을 때의 진입점.

    과목 매칭 + 주차 분류를 새로 수행한다(통합 분류는 콘텐츠 해시 캐시로 0 LLM 가능).
    """
    _run_with_fresh_engine(lambda Session: _dispatch_material_entry(file_id, Session))


async def _dispatch_material_entry(file_id: str, SessionLocal) -> None:
    async with metrics.pipeline("material", file_id=file_id):
        await _dispatch_material(file_id, SessionLocal)


# 배치는 여러 파일(추출+분류+파싱)을 한 태스크로 처리 → 전역 soft_time_limit(180초)로는
# 파일이 많을 때 3분에 걸려 죽고 일부 파일이 미처리로 남는다. 배치 전용으로 상향한다.
# (파일별 OpenAI 타임아웃 + Phase 병렬화로 실제로는 훨씬 빨리 끝난다 — 이건 안전 여유.)
@celery_app.task(name="tasks.process_auto_batch", soft_time_limit=600, time_limit=720)
def process_auto_batch_task(file_ids: list[str], user_id: str) -> None:
    """여러 파일을 한 번에 자동 분류 업로드한 배치를 처리.

    핵심: 강의계획서를 먼저 처리(과목+일정 생성)한 뒤 강의자료를 처리한다.
    그래야 강의자료의 과목 자동 매칭이 방금 생성된 과목에 정확히 붙어 중복 과목이 안 생긴다.
    Phase 1(추출+분류)·Phase 4(자료 처리)는 파일별로 병렬, Phase 3(강의계획서)만 순차.
    """
    _run_with_fresh_engine(lambda Session: _run_auto_batch(file_ids, user_id, Session))


@celery_app.task(name="tasks.generate_summary")
def generate_summary_task(file_id: str) -> None:
    """파일 텍스트 → AI 요약 노트 생성 후 ai_contents 에 저장."""
    _run_with_fresh_engine(lambda Session: _run_generate_summary(file_id, Session))


@celery_app.task(name="tasks.analyze_file")
def analyze_file_task(file_id: str) -> None:
    """파일 텍스트 → 분석본(analysis) 생성. 학습 콘텐츠 생성기들의 공유 입력.

    한 번 만들어두면 퀴즈/플래시카드/마인드맵/암기/주요 주제 모두 이 압축본을 입력으로 써서
    토큰 사용량과 latency 가 5배 가까이 감소.
    """
    _run_with_fresh_engine(lambda Session: _run_analyze_file(file_id, Session))


@celery_app.task(name="tasks.generate_ai_content")
def generate_ai_content_task(
    file_id: str,
    content_type: str,
    scope: str = "all",
    force: bool = False,
    requested_by_user_id: str | None = None,
    exclude_questions: list[str] | None = None,
    instructions: str | None = None,
) -> None:
    """학습 탭의 quiz/flashcard/mindmap/memorize/topics 생성 작업.

    iOS의 generate POST 호출은 이 태스크를 큐잉만 하고 즉시 202 반환한다.
    실제 GPT 호출은 워커에서 진행되어 사용자가 다른 탭으로 이동해도 결과가 안전하게 저장됨.

    `exclude_questions` 는 퀴즈 전용 — 이전에 사용자가 풀었던 문제 텍스트 리스트.
    있으면 force=True 처럼 동작하면서 GPT 에 '이 문제들과 다르게 출제' 를 지시한다.
    `instructions` 도 퀴즈 전용 — 사용자 추가 지침. 있으면 캐시를 덮어쓰고 새로 만든다.
    """
    _run_with_fresh_engine(
        lambda Session: _run_generate_ai_content(
            file_id, content_type, scope, force, requested_by_user_id, Session,
            exclude_questions=exclude_questions, instructions=instructions,
        )
    )


# notify_classified 는 Day 7 이후 app/tasks/notify_tasks.py 로 이관됨.
# 호출은 .delay(...)로 같은 이름 ("tasks.notify_classified")으로 발송하므로 변경 없음.

# ---------- Pipeline: text extraction ----------

async def _extract_text_into(session: AsyncSession, file_row: File) -> tuple[str | None, bool]:
    """파일의 S3 객체를 내려받아 텍스트를 추출하고 file_row.extracted_text / status 를 갱신한다.

    dispatch(후속 태스크 큐잉) 는 하지 않는다 — 호출자가 결정.
    반환: (text, ok). ok=False 면 내부에서 이미 _mark_failed 했으므로 호출자는 중단.

    단일 흐름(_run_extract)과 배치 흐름(_run_auto_batch) 양쪽에서 재사용한다.
    """
    file_row.status = "processing"
    file_row.parse_error = None
    await session.commit()

    # 유튜브: S3 객체가 없는 리소스 → 자막을 추출한다(S3 다운로드 우회).
    if file_row.file_type == "youtube":
        return await _extract_youtube_into(session, file_row)

    try:
        data = await asyncio.to_thread(s3.download_to_bytes, file_row.s3_key)
    except Exception as exc:
        logger.exception("extract_text: S3 download failed for %s", file_row.id)
        await _mark_failed(session, file_row, f"S3 download failed: {exc}")
        return None, False

    text: str | None = None
    if file_row.file_type == "pdf":
        # 플래그가 켜져 있으면 구조보존 마크다운 추출(pymupdf4llm). 미설치/실패 시
        # extract_markdown_from_pdf_bytes 내부에서 raw 텍스트로 자동 폴백한다.
        pdf_extractor = (
            extract_markdown_from_pdf_bytes
            if settings.PDF_MARKDOWN_EXTRACTION
            else extract_text_from_pdf_bytes
        )
        try:
            text = await asyncio.to_thread(pdf_extractor, data)
        except Exception as exc:
            logger.exception("extract_text: PyMuPDF failed for %s", file_row.id)
            await _mark_failed(session, file_row, f"PDF text extraction failed: {exc}")
            return None, False

        # OCR fallback — PyMuPDF 가 거의 빈 결과를 돌려준 경우 (손글씨/스캔 PDF).
        from app.services.ocr_fallback import needs_ocr, ocr_pdf, OCRError
        if needs_ocr(text):
            logger.info(
                "extract_text: triggering OCR fallback for file=%s (got %d chars from PyMuPDF)",
                file_row.id, len(text or ""),
            )
            try:
                ocr_text = await ocr_pdf(data)
                if ocr_text and len(ocr_text.strip()) > len(text or ""):
                    text = ocr_text
                    logger.info(
                        "extract_text: OCR fallback succeeded file=%s chars=%d",
                        file_row.id, len(ocr_text),
                    )
            except OCRError as exc:
                logger.warning(
                    "extract_text: OCR fallback failed file=%s: %s", file_row.id, exc,
                )

    elif file_row.file_type == "pptx":
        try:
            text = await asyncio.to_thread(extract_text_from_pptx_bytes, data)
        except Exception as exc:
            logger.exception("extract_text: python-pptx failed for %s", file_row.id)
            await _mark_failed(session, file_row, f"PPTX text extraction failed: {exc}")
            return None, False

    elif file_row.file_type == "docx":
        try:
            text = await asyncio.to_thread(extract_text_from_docx_bytes, data)
        except Exception as exc:
            logger.exception("extract_text: python-docx failed for %s", file_row.id)
            await _mark_failed(session, file_row, f"DOCX text extraction failed: {exc}")
            return None, False

    elif file_row.file_type == "image":
        # 이미지엔 임베드된 텍스트 레이어가 없다 → 항상 OCR(GPT-4o-mini vision)로 추출.
        # PDF OCR fallback 과 같은 경로(_ocr_single_page)를 페이지 렌더링 없이 재사용한다.
        from app.services.ocr_fallback import ocr_image, OCRError
        try:
            text = await ocr_image(data)
        except OCRError as exc:
            logger.warning("extract_text: image OCR unavailable file=%s: %s", file_row.id, exc)
            text = ""
        except Exception as exc:
            logger.exception("extract_text: image OCR failed for %s", file_row.id)
            await _mark_failed(session, file_row, f"Image OCR failed: {exc}")
            return None, False
        logger.info(
            "extract_text: image OCR file=%s chars=%d", file_row.id, len(text or ""),
        )

    file_row.extracted_text = text
    # 강의계획서인데 텍스트가 비어 있으면 parse를 트리거할 수 없다 → 명시적 실패.
    if file_row.is_syllabus and not (text and text.strip()):
        await _mark_failed(
            session, file_row,
            "강의계획서에서 텍스트를 추출하지 못했어요. 사진이 흐리거나 글자가 없는(이미지만 있는) 자료인지 확인해 주세요.",
        )
        return None, False

    file_row.status = "extracted"
    await session.commit()

    text_preview = (text or "").strip().replace("\n", " ")[:200]
    logger.info(
        "extract_text: file=%s chars=%d preview=%r",
        file_row.id, len(text or ""), text_preview,
    )
    return text, True


async def _extract_youtube_into(session: AsyncSession, file_row: File) -> tuple[str | None, bool]:
    """유튜브 영상 자막을 추출해 extracted_text 에 채운다(S3 우회).

    youtube 는 항상 강의자료(material)다 — 후속 디스패치는 호출자(_run_extract)가 담당.
    """
    from app.services.youtube_extractor import (
        fetch_transcript_for_url,
        YouTubeTranscriptUnavailable,
    )

    url = file_row.external_url or ""
    try:
        text = await asyncio.to_thread(fetch_transcript_for_url, url)
    except YouTubeTranscriptUnavailable as exc:
        # 사용자에게 보여줄 친화적 메시지가 담긴 예외 — 그대로 parse_error 로.
        await _mark_failed(session, file_row, str(exc))
        return None, False
    except Exception as exc:
        logger.exception("extract_text: youtube transcript 예외 file=%s", file_row.id)
        await _mark_failed(session, file_row, f"유튜브 자막 추출 실패: {exc}")
        return None, False

    file_row.extracted_text = text
    file_row.status = "extracted"
    await session.commit()
    logger.info(
        "extract_text(youtube): file=%s chars=%d url=%s",
        file_row.id, len(text or ""), url,
    )
    return text, True


async def _run_extract(file_id: str, SessionLocal) -> None:
    async with metrics.pipeline("ingest", file_id=file_id):
        async with SessionLocal() as session:
            file_row = await _load_file(session, UUID(file_id))
            if file_row is None:
                logger.warning("extract_text: file %s not found", file_id)
                return
            if file_row.status not in ("pending", "uploading"):
                logger.info(
                    "extract_text: skip file=%s status=%s (already dispatched)",
                    file_id, file_row.status,
                )
                return

            async with metrics.stage("extract_text"):
                text, ok = await _extract_text_into(session, file_row)
            if not ok:
                return

        # Auto-classify 분기: 사용자가 학기/과목/타입 지정 없이 올린 파일.
        # 업로드 시점에 classification_source="auto_pending" 으로 marker 가 찍힘.
        # 여기서 텍스트 보고 syllabus vs material 판정 + (material 이면) 과목 자동 매칭/생성.
        if file_row.classification_source == "auto_pending":
            await _auto_dispatch(file_id, SessionLocal)
            return

        if file_row.is_syllabus and text:
            parse_syllabus_task.delay(file_id)
        elif not file_row.is_syllabus:
            # Day 4: 일반 강의 자료는 주차 자동 분류 파이프라인으로 넘긴다.
            # PDF가 아니어서 text가 None이어도 파일명 regex만으로 분류 시도할 수 있다.
            classify_file_task.delay(file_id)


# ---------- Auto upload dispatch ----------

async def _auto_dispatch(file_id: str, SessionLocal) -> None:
    """auto_pending 파일을 보고 syllabus / material 결정 후 적절한 후속 태스크 디스패치.

    - syllabus 판정: is_syllabus=True, classification_source="auto_syllabus" → parse_syllabus_task
    - material 판정: 과목 자동 매칭/신규생성 → course_id 채움 → classify_file_task
    - 불확실/저신뢰(needs_review): 자동 결정 보류 → status="needs_review" 로 두고
      사용자에게 doc_type 확인을 요청 (confirm_file_kind 엔드포인트).
    학기가 하나도 없으면 명확한 메시지로 실패 처리.
    """
    async with SessionLocal() as session:
        file_row = await _load_file(session, UUID(file_id))
        if file_row is None:
            return

        text = file_row.extracted_text or ""
        async with metrics.stage("doc_classify"):
            decision = await decide_document_kind(text, file_row.filename)
        logger.info(
            "auto_dispatch: file=%s kind=%s doc_type=%s confidence=%.2f "
            "model=%s escalated=%s needs_review=%s reason=%s",
            file_id, decision.kind, decision.doc_type, decision.confidence,
            decision.used_model, decision.escalated, decision.needs_review, decision.reason,
        )

        # 저신뢰/불확실 — 억지로 결정하지 않고 사용자에게 되묻는다.
        if decision.needs_review:
            file_row.is_syllabus = decision.kind == "syllabus"  # 잠정 추정값(UI 기본 선택용)
            file_row.classification_source = "auto_uncertain"
            file_row.ai_confidence = round(decision.confidence, 4)
            file_row.status = "needs_review"
            await session.commit()
            return

        if decision.kind == "syllabus":
            file_row.is_syllabus = True
            file_row.classification_source = "auto_syllabus"
            await session.commit()
            if text.strip():
                parse_syllabus_task.delay(file_id)
            else:
                await _mark_failed(
                    session, file_row,
                    "강의계획서로 판정됐으나 텍스트가 비어있어요. 이미지 PDF 인지 확인해주세요.",
                )
            return

    # material — 과목 자동 매칭/생성은 별도 세션에서 (위 with 블록 종료 후).
    # 분류 결과를 넘겨 과목명 LLM 재호출을 피한다(이미 신원 신호를 추출했으면 재사용).
    await _dispatch_material(file_id, SessionLocal, classification=decision)


async def _resolve_course_identity(
    text: str, filename: str, classification: DocClassification | None,
) -> tuple[str, str | None, list[str]]:
    """(과목명, 교수, subject_keywords) 결정. LLM 추가 호출 최소화.

    우선순위:
      1) 통합 분류가 이미 추출한 과목명/교수/키워드 (LLM 추가 0회)
      2) 본문 머리글 "<과목명> (<코드>)" regex / 파일명 regex (LLM 0회)
      3) 둘 다 실패 + 분류를 아직 안 했으면 classify_document 1회(캐시 적중 시 0회)
      4) 그래도 없으면 "기타"
    subject_keywords 는 과목 매칭이 모호할 때 LLM 디스앰비규에이션의 결정적 단서가 된다.
    """
    professor: str | None = None
    keywords: list[str] = []
    if classification is not None:
        name = (classification.signals.course_name_guess or "").strip()
        professor = (classification.signals.professor or "").strip() or None
        keywords = list(classification.signals.subject_keywords or [])
        if len(name) >= 2:
            return name, professor, keywords

    # 본문 머리글 "<과목명> (<코드>)" — 값싼 고신뢰 신호.
    header_name, _code = guess_course_identity_from_text(text)
    if header_name and len(header_name) >= 2:
        return header_name, professor, keywords

    # 본문이 있으면 LLM 으로 텍스트 기반 과목명 추출 — **파일명보다 본문을 우선**한다.
    # 파일명은 'material_calc' 처럼 과목과 무관/축약된 경우가 많아, 본문에 과목명이 분명히
    # 있으면 그쪽이 정확하다(예: 본문 "미적분학 4주차 필기" → 기존 '미적분학' 과목에 매칭).
    # 콘텐츠 해시 캐시로 대개 추가 LLM 0회.
    if (text or "").strip():
        c = await classify_document(text, filename)
        name = (c.signals.course_name_guess or "").strip()
        # 이름이 약해도 교수/키워드는 확보 — 아래 파일명 폴백/'기타' 여도 과목 매칭에 쓰인다
        # (키워드로 기존 과목에 내용 매칭 → 'Leccion 2' 같은 자료가 새 과목으로 새지 않음).
        professor = professor or ((c.signals.professor or "").strip() or None)
        if not keywords:
            keywords = list(c.signals.subject_keywords or [])
        if len(name) >= 2:
            return name, professor, keywords

    # 파일명 폴백 (본문에서 과목명을 못 얻었을 때만).
    fn = guess_course_name_from_filename(filename)
    if fn and len(fn) >= 2:
        return fn, professor, keywords
    return "기타", professor, keywords


async def _dispatch_material(
    file_id: str,
    SessionLocal,
    classification: DocClassification | None = None,
) -> None:
    """auto 강의자료 처리: 과목명 추정 → 과목 매칭/신규생성 → course_id 채움 → 주차 분류 큐잉.

    배치 흐름(Phase 4)에서도 호출 — 이 때는 syllabus 들이 이미 과목을 생성한 뒤라
    match_or_create_course 가 기존 과목에 정확히 매칭된다 (중복 과목 생성 방지).
    """
    async with SessionLocal() as session:
        file_row = await _load_file(session, UUID(file_id))
        if file_row is None:
            return
        text = file_row.extracted_text or ""

        user = await session.get(User, file_row.uploaded_by_user_id) if file_row.uploaded_by_user_id else None
        if user is None:
            await _mark_failed(session, file_row, "업로드 사용자 정보를 찾을 수 없어요.")
            return

        async with metrics.stage("course_match"):
            course_name, professor, keywords = await _resolve_course_identity(
                text, file_row.filename or "", classification,
            )
            try:
                course, _semester, created = await match_or_create_course(
                    session, user, course_name, professor, subject_keywords=keywords,
                    text_snippet=(text or "")[:700],
                )
            except CourseMatchError as exc:
                await _mark_failed(
                    session, file_row,
                    f"활성 학기가 없어 과목을 자동 생성할 수 없어요. 학기를 먼저 만들어주세요. ({exc})",
                )
                return

        file_row.course_id = course.id
        file_row.is_syllabus = False
        file_row.classification_source = "auto_material"
        await session.commit()
        logger.info(
            "dispatch_material: file=%s → course=%s (%s, created=%s)",
            file_id, course.id, course.name, created,
        )
    classify_file_task.delay(file_id)


# ---------- Batch auto upload: 강의계획서 먼저, 그 다음 강의자료 ----------

async def _ingest_one_for_batch(fid: str, SessionLocal):
    """배치의 한 파일을 추출 + 통합 분류한다.

    반환: ("syllabus" | "material" | "skip", fid, decision|None).
    create_task 로 호출돼 contextvar 가 격리되므로 자체 metrics.pipeline 을 연다.
    """
    async with metrics.pipeline("ingest", file_id=fid):
        async with SessionLocal() as session:
            file_row = await _load_file(session, UUID(fid))
            if file_row is None:
                logger.warning("auto_batch: file %s not found", fid)
                return ("skip", fid, None)
            # 이미 다른 경로로 처리 시작된 파일은 건너뜀 (중복 confirm 방어).
            if file_row.status not in ("pending", "uploading"):
                logger.info(
                    "auto_batch: skip file=%s status=%s (already processing)",
                    fid, file_row.status,
                )
                return ("skip", fid, None)

            async with metrics.stage("extract_text"):
                text, ok = await _extract_text_into(session, file_row)
            if not ok:
                return ("skip", fid, None)  # _mark_failed 됨

            async with metrics.stage("doc_classify"):
                decision = await decide_document_kind(text or "", file_row.filename)
            logger.info(
                "auto_batch: classify file=%s kind=%s doc_type=%s confidence=%.2f "
                "model=%s needs_review=%s reason=%s",
                fid, decision.kind, decision.doc_type, decision.confidence,
                decision.used_model, decision.needs_review, decision.reason,
            )

            if decision.needs_review:
                file_row.is_syllabus = decision.kind == "syllabus"
                file_row.classification_source = "auto_uncertain"
                file_row.ai_confidence = round(decision.confidence, 4)
                file_row.status = "needs_review"
                await session.commit()
                return ("skip", fid, None)

            if decision.kind == "syllabus":
                file_row.is_syllabus = True
                file_row.classification_source = "auto_syllabus"
                await session.commit()
                if text and text.strip():
                    return ("syllabus", fid, decision)
                await _mark_failed(
                    session, file_row,
                    "강의계획서로 판정됐으나 텍스트가 비어있어요. 이미지 PDF 인지 확인해주세요.",
                )
                return ("skip", fid, None)

            file_row.is_syllabus = False
            file_row.classification_source = "auto_material_pending"
            await session.commit()
            return ("material", fid, decision)


async def _run_auto_batch(file_ids: list[str], user_id: str, SessionLocal) -> None:
    """여러 파일을 phase 별로 처리해 강의계획서 → 강의자료 순서를 보장한다.

    Phase 1+2) 각 파일 텍스트 추출 + syllabus/material 분류
    Phase 3)   syllabus 들을 inline 으로 파싱 (과목 + 일정 생성). await 로 완료 보장.
    Phase 4)   material 들을 처리 (이제 syllabus 가 만든 과목에 매칭됨)
    """
    logger.info("auto_batch: start count=%d user=%s", len(file_ids), user_id)
    syllabus_ids: list[str] = []
    material_ids: list[str] = []
    # material 파일의 통합 분류 결과(과목명/교수/keywords)를 Phase 4 로 운반 — 재호출 방지.
    material_class: dict[str, DocClassification] = {}

    # ----- Phase 1+2: 추출 + 분류 (파일별 독립 → 병렬) -----
    # 동시성 상한(semaphore)으로 묶고, 각 파일을 create_task 로 띄워 metrics contextvar 를
    # 격리한다. LLM/임베딩 대기가 겹쳐 다건 업로드 지연시간이 크게 준다.
    sem = asyncio.Semaphore(max(1, settings.BATCH_INGEST_CONCURRENCY))

    async def _guarded(fid: str):
        async with sem:
            try:
                return await _ingest_one_for_batch(fid, SessionLocal)
            except Exception:
                logger.exception("auto_batch: extract/classify failed for %s", fid)
                return ("skip", fid, None)

    outcomes = await asyncio.gather(
        *(asyncio.create_task(_guarded(fid)) for fid in file_ids)
    )
    for kind, fid, decision in outcomes:
        if kind == "syllabus":
            syllabus_ids.append(fid)
        elif kind == "material":
            material_ids.append(fid)
            material_class[fid] = decision

    logger.info(
        "auto_batch: classified syllabus=%d material=%d",
        len(syllabus_ids), len(material_ids),
    )

    # ----- Phase 3: 강의계획서 먼저 (과목 + 일정 생성). inline await 로 완료 보장 -----
    for fid in syllabus_ids:
        try:
            await _run_parse_syllabus(fid, SessionLocal)
        except Exception:
            logger.exception("auto_batch: syllabus parse failed for %s", fid)

    # ----- Phase 4: 강의자료 (이제 과목이 존재하므로 매칭됨) -----
    # 병렬 처리 — 한 파일의 LLM 호출이 느려도(또는 잠깐 멈춰도) 나머지 파일이 뒤에서
    # 막히지 않는다. (예전 순차 처리 + 타임아웃 부재가 '일부 파일이 3분 뒤 뜸'의 원인.)
    async def _dispatch_guarded(fid: str):
        async with sem:
            try:
                async with metrics.pipeline("material", file_id=fid):
                    await _dispatch_material(
                        fid, SessionLocal, classification=material_class.get(fid),
                    )
            except Exception:
                logger.exception("auto_batch: material dispatch failed for %s", fid)

    await asyncio.gather(
        *(asyncio.create_task(_dispatch_guarded(fid)) for fid in material_ids)
    )

    logger.info("auto_batch: done count=%d", len(file_ids))


# ---------- Pipeline: syllabus parsing ----------

async def _run_parse_syllabus(file_id: str, SessionLocal) -> None:
    # context manager 로 감싸 early return/예외 경로에서도 메트릭이 항상 기록되게 한다.
    async with metrics.pipeline("syllabus", file_id=file_id):
        await _run_parse_syllabus_impl(file_id, SessionLocal)


async def _run_parse_syllabus_impl(file_id: str, SessionLocal) -> None:
    async with SessionLocal() as session:
        file_row = await _load_file(session, UUID(file_id))
        if file_row is None:
            logger.warning("parse_syllabus: file %s not found", file_id)
            return
        if file_row.status in ("parsing", "parsed"):
            logger.info("parse_syllabus: skip file=%s status=%s", file_id, file_row.status)
            return

        if not file_row.extracted_text:
            await _mark_failed(session, file_row, "No extracted_text to parse")
            return

        # ----- 학기/유저 컨텍스트 결정 -----
        # 경로 A) course가 이미 결정된 일반 흐름 → 그 course의 semester 사용
        # 경로 B) 과목 미선택으로 업로드된 강의계획서 → uploaded_by_user_id 의 active semester
        course: Course | None = None
        semester: Semester | None = None
        user_id = file_row.uploaded_by_user_id

        if file_row.course_id is not None:
            course = await session.get(Course, file_row.course_id)
            if course is None:
                await _mark_failed(session, file_row, "Course not found")
                return
            semester = await session.get(Semester, course.semester_id)
            if semester is None:
                await _mark_failed(session, file_row, "Semester not found")
                return
            if user_id is None:
                # 과거 데이터 호환: uploaded_by_user_id 가 비어 있으면 course→semester→user 로 채워둠
                user_id = semester.user_id
                file_row.uploaded_by_user_id = user_id
        else:
            # 경로 B — semester 결정은 course_matcher 가 파싱 후 일괄 처리하지만,
            # parser 호출엔 year/term이 필요하므로 미리 같은 semester picker를 한 번 돌린다.
            if user_id is None:
                await _mark_failed(session, file_row, "Owner not recorded for syllabus")
                return
            user = await session.get(User, user_id)
            if user is None:
                await _mark_failed(session, file_row, "Owner user not found")
                return
            try:
                from app.services.course_matcher import _pick_target_semester  # type: ignore
                semester = await _pick_target_semester(session, user)
            except CourseMatchError as exc:
                await _mark_failed(session, file_row, str(exc))
                return

        year, term = _derive_year_term(semester)
        file_row.status = "parsing"
        await session.commit()

        # 표 추출 시도 — 성공 시 LLM 호출이 작아져 latency 절반 감소.
        # 실패해도 fallback (전체 LLM 호출) 으로 안전하게 진행.
        prefilled_weeks = None
        if settings.SYLLABUS_TABLE_EXTRACTION_ENABLED and file_row.file_type == "pdf":
            try:
                pdf_bytes = await asyncio.to_thread(s3.download_to_bytes, file_row.s3_key)
                prefilled_weeks = await asyncio.to_thread(extract_tables_from_pdf, pdf_bytes)
                if prefilled_weeks:
                    logger.info(
                        "[PARSE_DEBUG] table extraction success: %d weeks pre-filled",
                        len(prefilled_weeks),
                    )
                else:
                    logger.info("[PARSE_DEBUG] table extraction empty — LLM fallback")
            except Exception as exc:
                # 표 추출은 best-effort. S3 재다운로드 실패 / PyMuPDF 예외 등은 무시.
                logger.warning("[PARSE_DEBUG] table extraction failed (%s) — LLM fallback", exc)
                prefilled_weeks = None

        try:
            result = await parse_syllabus(
                file_row.extracted_text,
                year=year,
                term=term,
                prefilled_weeks=prefilled_weeks,
            )
        except SyllabusParseError as exc:
            logger.exception("parse_syllabus failed for %s", file_id)
            await _mark_failed(session, file_row, f"Syllabus parse failed: {exc}")
            return

        # ----- 경로 B 후처리: 파싱된 강의명으로 course 매칭/생성 -----
        if course is None:
            parsed_course_name = result.syllabus.course.name.strip()
            if not parsed_course_name:
                await _mark_failed(session, file_row, "Syllabus has no course name to match")
                return
            user = await session.get(User, user_id)  # type: ignore[arg-type]
            try:
                course, semester, created = await match_or_create_course(
                    session,
                    user=user,
                    course_name=parsed_course_name,
                    professor=result.syllabus.course.professor,
                )
            except CourseMatchError as exc:
                await _mark_failed(session, file_row, str(exc))
                return
            file_row.course_id = course.id
            logger.info(
                "[PARSE_DEBUG] auto-bound file=%s → course=%s (%r) %s",
                file_id, course.id, course.name, "(created)" if created else "(matched)",
            )

        # === DEBUG: 파싱 결과 전체 덤프 ===
        syllabus = result.syllabus
        logger.info(
            "[PARSE_DEBUG] file=%s course=%s/%s semester_start=%s year=%d term=%s confidence=%.2f",
            file_id, course.id, course.name, semester.start_date, year, term, syllabus.confidence,
        )
        logger.info(
            "[PARSE_DEBUG] counts: weeks=%d exams=%d assignments=%d warnings=%d",
            len(syllabus.weeks), len(syllabus.exams), len(syllabus.assignments), len(syllabus.warnings),
        )
        for i, w in enumerate(syllabus.weeks):
            logger.info("[PARSE_DEBUG] week[%d]: #%d %r %r", i, w.week_number, w.topic, w.notes)
        for i, e in enumerate(syllabus.exams):
            logger.info(
                "[PARSE_DEBUG] exam[%d]: title=%r exam_date=%s start=%s end=%s location=%r",
                i, e.title, e.exam_date, e.start_time, e.end_time, e.location,
            )
        for i, a in enumerate(syllabus.assignments):
            logger.info(
                "[PARSE_DEBUG] assignment[%d]: title=%r due_date=%s",
                i, a.title, a.due_date,
            )
        for w in syllabus.warnings:
            logger.info("[PARSE_DEBUG] warning: %s", w)

        # 같은 course의 기존 AI 자동 일정 정리 (재파싱/재업로드 시 중복 방지)
        # 먼저 그 course의 auto todos를 전부 지운다. schedule 에 매달린 것뿐 아니라
        # 날짜 미지정(schedule_id=None) auto todo 도 있으므로 course_id 기준으로 싹 정리한다
        # (강의계획서가 다시 truth — 재파싱 시 아래에서 전부 재생성).
        await session.execute(
            delete(Todo).where(
                Todo.is_auto.is_(True),
                Todo.course_id == course.id,
            )
        )
        deleted = await session.execute(
            delete(Schedule).where(
                Schedule.course_id == course.id,
                Schedule.is_auto.is_(True),
            )
        )
        logger.info(
            "[PARSE_DEBUG] cleared %d existing is_auto schedules for course=%s before re-insert",
            deleted.rowcount or 0, course.id,
        )

        inserted_rows, undated_todo_specs = _insert_schedules(
            session, course.id, syllabus, semester.start_date,
        )

        # schedule.id 확보를 위해 flush 후 auto todos 생성 (일정 당일 1건)
        await session.flush()
        todos_added = 0
        for sched in inserted_rows:
            for spec in build_auto_todos(sched):
                session.add(Todo(**spec))
                todos_added += 1
        # 날짜를 못 구한 시험/과제 — 날짜 미지정 todo 로 과목에 추가 (캘린더엔 안 올라감).
        for spec in undated_todo_specs:
            session.add(Todo(**spec))
            todos_added += 1
        logger.info(
            "[PARSE_DEBUG] generated %d auto todos for %d schedules (+%d 날짜 미지정)",
            todos_added, len(inserted_rows), len(undated_todo_specs),
        )

        # 강의계획서에 강의실 정보가 있으면 저장 (없으면 기존 값 유지).
        if syllabus.course.location:
            course.location = syllabus.course.location.strip() or None

        # 강의 정기 시간표(요일/시작/종료) — 시간표 뷰의 데이터 소스.
        # ParsedClassTime 은 time 타입이라 isoformat 으로 직렬화한다.
        course.schedule = [
            {
                "day": ct.day,
                "start_time": ct.start_time.strftime("%H:%M"),
                "end_time": ct.end_time.strftime("%H:%M"),
            }
            for ct in syllabus.course.class_times
        ] or None

        # 수업시간이 특수 표기면 결정론적으로 재계산해 LLM 오해를 덮어쓴다.
        #  (1) 교시("월2,3,4,...") → 연대 기준 시각 (2,3,4교시=10:00~12:50)
        #  (2) 영어 요일범위("Mon-Thur (11:00 am~12:40 pm)") → 범위를 전부 펼침(월·화·수·목)
        raw_text = file_row.extracted_text or ""
        period_ct = parse_period_class_times(raw_text)
        english_ct = parse_english_class_times(raw_text) if not period_ct else []
        override_ct = period_ct or english_ct
        if override_ct:
            course.schedule = override_ct
            logger.info(
                "[PARSE] 특수 수업시간 표기 감지(%s) → class_times 재계산 file=%s → %s",
                "교시" if period_ct else "요일범위", file_id, override_ct,
            )

        # 임베딩 캐시 재사용 가능 여부 — weeks 덮어쓰기 _전에_ 비교해야 의미 있음.
        # (week_number, topic) 셋이 동일하면 OpenAI embeddings API 호출(~1.5s) skip.
        old_keys = {
            (w["week_number"], (w.get("topic") or "").strip())
            for w in (course.weekly_topics or [])
        }
        new_keys = {
            (w.week_number, (w.topic or "").strip())
            for w in syllabus.weeks
        }
        embeddings_reusable = (
            bool(course.weekly_topic_embeddings)
            and bool(old_keys)
            and old_keys == new_keys
        )

        # Day 4: 주차별 토픽을 Course에 캐시. 자료 자동 분류의 기준 데이터가 된다.
        course.weekly_topics = [
            {"week_number": w.week_number, "topic": w.topic, "notes": w.notes}
            for w in syllabus.weeks
        ]

        if embeddings_reusable:
            logger.info(
                "[PARSE_DEBUG] reusing %d cached week embeddings for course=%s (no topic change)",
                len(syllabus.weeks), course.id,
            )
        else:
            try:
                embeddings = await build_weekly_topic_embeddings(syllabus.weeks)
                course.weekly_topic_embeddings = serialize_week_embeddings(embeddings)
                logger.info(
                    "[PARSE_DEBUG] cached %d week embeddings for course=%s",
                    len(embeddings), course.id,
                )
            except EmbeddingClassifierError as exc:
                logger.warning(
                    "[PARSE_DEBUG] week embedding build failed for course=%s: %s",
                    course.id, exc,
                )

        file_row.status = "parsed"
        file_row.ai_confidence = syllabus.confidence
        await session.commit()

        logger.info(
            "[PARSE_DEBUG] inserted %d schedules for file=%s",
            len(inserted_rows), file_id,
        )
        for r in inserted_rows:
            logger.info(
                "[PARSE_DEBUG] -> id=%s type=%s title=%r due=%s",
                r.id, r.type, r.title, r.due_date.isoformat(),
            )

        logger.info(
            "parse_syllabus: file=%s schedules_inserted=%d confidence=%.2f tokens=%d",
            file_id, len(inserted_rows), syllabus.confidence, result.usage.total_tokens,
        )


# ---------- Helpers ----------

async def _load_file(session: AsyncSession, file_id: UUID) -> File | None:
    result = await session.execute(select(File).where(File.id == file_id))
    return result.scalar_one_or_none()


async def _mark_failed(session: AsyncSession, file_row: File, message: str) -> None:
    file_row.status = "failed"
    file_row.parse_error = message[:1000]
    await session.commit()


def _derive_year_term(semester: Semester) -> tuple[int, str]:
    """semesters에 year/term 컬럼이 없으므로 start_date로 추론."""
    year = semester.start_date.year
    month = semester.start_date.month
    if 3 <= month <= 6:
        term = "1"
    elif 9 <= month <= 12:
        term = "2"
    elif 7 <= month <= 8:
        term = "summer"
    else:
        term = "winter"
    return year, term


def _to_datetime(d, t=None) -> datetime | None:
    if d is None:
        return None
    if t is None:
        return datetime.combine(d, datetime.min.time())
    return datetime.combine(d, t)


def _week_to_date(week_number: int | None, semester_start) -> datetime | None:
    """학기 시작일 + (week-1)*7일로 대략적인 날짜 추정. week이 None이면 None."""
    if not week_number or week_number < 1:
        return None
    return datetime.combine(semester_start, datetime.min.time()) + timedelta(days=(week_number - 1) * 7)


def _snap_year_to_semester(due: datetime | None, semester_start) -> datetime | None:
    """명시된 시험/과제 날짜의 **연도 오타**를 학기 컨텍스트로 보정한다.

    강의계획서를 이전 학기 것에서 복사하며 연도만 안 고치는 실수가 흔하다.
    예) 2026 여름학기(주차 기간 2026-06~07)인데 '중간고사_2025.07.08 예정' 처럼 시험만
        작년 연도로 적혀 있으면, 파서가 그대로 2025-07-08 로 등록 → 캘린더/할일이 1년
        과거로 뜬다(D+365...).

    시험·과제는 학기 시작 전일 수 없으므로, due 가 학기 시작보다 14일 넘게 이르면 연도를
    한 해씩 앞으로 당겨 학기 창 안으로 들어오게 맞춘다. 겨울 계절학기처럼 학기 시작 이후
    정상적으로 다음 해로 넘어가는 날짜(due >= 시작)는 절대 건드리지 않는다.
    """
    if due is None:
        return None
    start = semester_start.date() if isinstance(semester_start, datetime) else semester_start
    margin = timedelta(days=14)
    guard = 0
    while due.date() < start - margin and guard < 3:
        try:
            due = due.replace(year=due.year + 1)
        except ValueError:
            # 2/29 → 다음 해가 비윤년이면 2/28 로 안전 조정.
            due = due.replace(year=due.year + 1, month=2, day=28)
        guard += 1
    return due


_EXAM_WEEK_RE = re.compile(r"(\d{1,2})\s*주", re.IGNORECASE)


def _guess_week_from_text(*texts: str | None) -> int | None:
    """제목/노트에서 'N주차' 패턴 추출."""
    for t in texts:
        if not t:
            continue
        m = _EXAM_WEEK_RE.search(t)
        if m:
            return int(m.group(1))
    return None


def _insert_schedules(
    session: AsyncSession,
    course_id: UUID,
    syllabus: ParsedSyllabus,
    semester_start,
) -> tuple[list[Schedule], list[dict]]:
    """파싱된 시험/과제 일정을 schedules 테이블에 자동 등록.

    날짜 매핑 우선순위:
      1) exam_date / due_date 가 명시되어 있으면 그대로
      2) 없으면 제목·노트에서 'N주차' 추출 → semester_start + (N-1)*7
      3) 그래도 없으면 'exam'은 weeks 배열에서 '중간/기말' 키워드 매칭으로 추정
      4) 다 실패하면(날짜를 끝내 못 구하면) **캘린더엔 못 올리므로 날짜 미지정 todo 로만 등록.**

    Returns:
        (inserted_schedules, undated_todo_specs)
        - inserted_schedules: 날짜가 있어 schedules 에 add 된 Schedule row 목록 (is_auto=True)
        - undated_todo_specs: 날짜를 못 구한 시험/과제의 todo dict 목록 (due_date=None, schedule_id=None)
    """
    inserted: list[Schedule] = []
    undated_todos: list[dict] = []

    # 1) 시험
    for exam in syllabus.exams:
        due = _to_datetime(exam.exam_date, exam.start_time)
        source = "exam_date"

        if due is None:
            week_guess = _guess_week_from_text(exam.title, exam.description)
            if week_guess is None:
                week_guess = _find_week_for_exam(syllabus.weeks, exam.title)
            due = _week_to_date(week_guess, semester_start)
            source = f"week#{week_guess}" if week_guess else "none"

        if due is None:
            spec = build_undated_todo(course_id, exam.title, "exam")
            if spec is not None:
                undated_todos.append(spec)
            logger.info("[PARSE_DEBUG] UNDATED exam %r → 날짜 미지정 todo (source=%s)", exam.title, source)
            continue

        # 연도 오타 보정 (예: 2026학기인데 명시된 시험일이 2025.xx) — 학기 창 안으로 당김.
        snapped = _snap_year_to_semester(due, semester_start)
        if snapped != due:
            logger.info(
                "[PARSE_DEBUG] exam %r 연도보정 %s → %s (학기시작 %s)",
                exam.title, due.date(), snapped.date(), semester_start,
            )
            due = snapped

        row = _schedule_from_exam(course_id, exam, due)
        session.add(row)
        inserted.append(row)
        logger.info("[PARSE_DEBUG] ADD exam %r at %s (source=%s)", exam.title, due.isoformat(), source)

    # 2) 과제
    for assignment in syllabus.assignments:
        due = _to_datetime(assignment.due_date)
        source = "due_date"

        if due is None:
            week_guess = _guess_week_from_text(assignment.title, assignment.description)
            due = _week_to_date(week_guess, semester_start)
            source = f"week#{week_guess}" if week_guess else "none"

        if due is None:
            spec = build_undated_todo(course_id, assignment.title, "assignment")
            if spec is not None:
                undated_todos.append(spec)
            logger.info("[PARSE_DEBUG] UNDATED assignment %r → 날짜 미지정 todo (source=%s)", assignment.title, source)
            continue

        # 연도 오타 보정 (시험과 동일 정책).
        snapped = _snap_year_to_semester(due, semester_start)
        if snapped != due:
            logger.info(
                "[PARSE_DEBUG] assignment %r 연도보정 %s → %s (학기시작 %s)",
                assignment.title, due.date(), snapped.date(), semester_start,
            )
            due = snapped

        row = _schedule_from_assignment(course_id, assignment, due)
        session.add(row)
        inserted.append(row)
        logger.info("[PARSE_DEBUG] ADD assignment %r at %s (source=%s)", assignment.title, due.isoformat(), source)

    return inserted, undated_todos


def _find_week_for_exam(weeks: list[ParsedWeek], exam_title: str) -> int | None:
    """weeks 배열에서 시험 제목과 매칭되는 주차 찾기."""
    title_lower = exam_title.lower()
    keywords = ["중간", "기말", "midterm", "final", "퀴즈", "quiz"]
    matched_kw = next((kw for kw in keywords if kw in title_lower), None)
    if not matched_kw:
        return None
    for w in weeks:
        text = f"{w.topic or ''} {w.notes or ''}".lower()
        if matched_kw in text:
            return w.week_number
    return None


def _schedule_from_exam(course_id: UUID, exam: ParsedExam, due: datetime) -> Schedule:
    desc_parts = []
    if exam.location:
        desc_parts.append(f"장소: {exam.location}")
    if exam.end_time:
        desc_parts.append(f"종료: {exam.end_time.strftime('%H:%M')}")
    if exam.description:
        desc_parts.append(exam.description)
    return Schedule(
        course_id=course_id,
        title=exam.title,
        type="exam",
        due_date=due,
        description="\n".join(desc_parts) or None,
        is_auto=True,
    )


def _schedule_from_assignment(course_id: UUID, assignment: ParsedAssignment, due: datetime) -> Schedule:
    return Schedule(
        course_id=course_id,
        title=assignment.title,
        type="assignment",
        due_date=due,
        description=assignment.description,
        is_auto=True,
    )


# ---------- Pipeline: classify file (Day 4) ----------

async def _run_classify(file_id: str, SessionLocal) -> None:
    # context manager 로 감싸 early return/예외 경로에서도 메트릭이 항상 기록되게 한다.
    async with metrics.pipeline("classify", file_id=file_id):
        await _run_classify_impl(file_id, SessionLocal)


async def _run_classify_impl(file_id: str, SessionLocal) -> None:
    async with SessionLocal() as session:
        file_row = await _load_file(session, UUID(file_id))
        if file_row is None:
            logger.warning("classify_file: file %s not found", file_id)
            return

        if file_row.is_syllabus:
            logger.info("classify_file: skip syllabus file %s", file_id)
            return

        # course_id가 None인 케이스 방어 — syllabus 외 일반 자료는 보통 course_id가 채워져 있지만,
        # race condition 또는 데이터 정합성 이슈로 None이 들어오면 session.get(Course, None) 이
        # InvalidRequestError 를 던진다. 미리 막는다.
        if file_row.course_id is None:
            await _mark_failed(session, file_row, "course_id가 비어 있어 자동 분류를 진행할 수 없습니다.")
            return

        course = await session.get(Course, file_row.course_id)
        if course is None:
            await _mark_failed(session, file_row, "Course not found")
            return

        file_row.status = "classifying"
        await session.commit()

        # 요약 + 분석본을 '분류'와 병렬로 미리 시작한다.
        # 둘 다 입력이 extracted_text 뿐이라 분류 결과를 기다릴 필요가 없다.
        # 기존엔 분류 commit("classified") 이후에야 큐잉했는데, 그 시점이
        # 리스트의 "준비 완료" 표시 시점과 같아서 → 사용자가 곧바로 파일에 들어가면
        # 요약 row 가 아직 없어 상세 화면이 "처리 중"으로 깜빡였다.
        # 분류와 병렬로 돌리면 "준비 완료"가 뜰 즈음 요약도 대부분 끝나 있다.
        if file_row.extracted_text and file_row.extracted_text.strip():
            generate_summary_task.delay(file_id)
            analyze_file_task.delay(file_id)

        week_embeddings = deserialize_week_embeddings(
            course.weekly_topic_embeddings or []
        )

        # OpenAI 호출이 실패해도 task 자체는 죽지 않도록 wrap. classify_by_embedding 은
        # 내부에서 EmbeddingClassifierError를 swallow하지만, 다른 경로에서 raw OpenAIError가
        # 새는 것을 대비한 안전망.
        try:
            async with metrics.stage("classify_file"):
                result = await classify_file(
                    filename=file_row.filename or "",
                    extracted_text=file_row.extracted_text,
                    week_embeddings=week_embeddings,
                )
        except Exception as exc:
            logger.exception("classify_file: 예상치 못한 오류 file=%s", file_id)
            await _mark_failed(session, file_row, f"자동 분류 실패: {exc}")
            return

        logger.info(
            "[CLASSIFY] file=%s filename=%r source=%s week=%s confidence=%.3f detail=%s",
            file_id, file_row.filename, result.source,
            result.week_number, result.confidence,
            json.dumps(result.detail, ensure_ascii=False),
        )

        if result.week_number is None:
            file_row.week = None
            file_row.ai_confidence = 0.0
            file_row.classification_source = None
            file_row.status = "unclassified"
        else:
            file_row.week = result.week_number
            file_row.ai_confidence = round(result.confidence, 4)
            file_row.classification_source = result.source
            file_row.status = "classified"

        await session.commit()

        # 변경 탐지 게이트(LLM 없음): 변경 키워드가 있을 때만 별도 태스크로 큐잉.
        should_detect = (
            settings.CHANGE_DETECTION_ENABLED
            and file_row.course_id is not None
            and has_change_signal(file_row.extracted_text)
        )

    if should_detect:
        detect_changes_task.delay(file_id)

    # 분류 결과와 무관하게 알림은 한 번 — UI에서 "미분류 폴더" 안내에도 쓰임.
    # notify_classified 태스크는 app/tasks/notify_tasks.py 로 이관됨. 이름 기반으로
    # send_task 호출 (import 회피).
    celery_app.send_task("tasks.notify_classified", args=[file_id])

    # 요약 + 분석본 큐잉은 위쪽(status="classifying" 직후)으로 이동해
    # 분류와 병렬로 돌린다. 분석본은 quiz/flashcard/mindmap/memorize/topics 의
    # 공유 입력으로 재활용된다. generate_summary_task/analyze_file_task 는 내부에
    # 중복 생성 가드가 있어 다른 경로에서 다시 호출돼도 안전하다.


# ---------- Pipeline: change detection (Stage 3) ----------

def _format_course_schedule(schedule: list | None) -> str:
    """course.schedule([{day,start_time,end_time}]) 를 사람이 읽는 문자열로."""
    if not schedule:
        return ""
    parts = []
    for slot in schedule:
        try:
            parts.append(f"{slot['day']} {slot['start_time']}-{slot['end_time']}")
        except (KeyError, TypeError):
            continue
    return ", ".join(parts)


def _match_schedule_id(title: str, rows: list[Schedule]) -> UUID | None:
    """변경 대상 제목으로 기존 일정을 best-effort 매칭. 정확/부분 일치 우선."""
    norm = "".join((title or "").split()).lower()
    if not norm:
        return None
    for s in rows:
        if "".join((s.title or "").split()).lower() == norm:
            return s.id
    for s in rows:
        sn = "".join((s.title or "").split()).lower()
        if sn and (norm in sn or sn in norm):
            return s.id
    return None


async def _run_detect_changes(file_id: str, SessionLocal) -> None:
    async with metrics.pipeline("change_detect", file_id=file_id):
        async with SessionLocal() as session:
            file_row = await _load_file(session, UUID(file_id))
            if file_row is None or file_row.is_syllabus or file_row.course_id is None:
                return
            text = file_row.extracted_text or ""
            if not has_change_signal(text):  # 게이트 재확인(중복 큐잉 방어).
                return

            course = await session.get(Course, file_row.course_id)
            if course is None:
                return

            sched_rows = (
                await session.execute(
                    select(Schedule).where(Schedule.course_id == course.id)
                )
            ).scalars().all()

            class_time_str = _format_course_schedule(course.schedule)
            assignments = [
                (s.title, s.due_date.strftime("%Y-%m-%d %H:%M")) for s in sched_rows
            ]
            # 비교 기준이 하나도 없으면(강의계획서 미파싱) 변경 탐지 의미 없음.
            if not class_time_str and not course.location and not assignments:
                return

            ctx = ChangeContext(
                class_time=class_time_str,
                location=course.location,
                assignments=assignments,
            )
            async with metrics.stage("detect_changes"):
                updates = await detect_changes(text, ctx)
            if not updates:
                return

            # 새 과제/일정은 **자동 반영**, 기존 항목 변경(강의시간/강의실/과제마감)은 **승인 제안**.
            new_items = [u for u in updates if u.field == "new_assignment"]
            change_items = [u for u in updates if u.field != "new_assignment"]

            def _norm_title(t: str | None) -> str:
                return "".join((t or "").split()).lower()

            # ----- (A) 새 과제 자동 생성: schedule(캘린더) + 마감 리마인더 todos(과제탭) -----
            added_assignments = 0
            if new_items:
                semester = await session.get(Semester, course.semester_id)
                sem_start = semester.start_date if semester is not None else None
                fallback_year = (
                    sem_start.year if sem_start is not None
                    else (sched_rows[0].due_date.year if sched_rows else datetime.now().year)
                )
                existing_assign = {
                    (_norm_title(s.title), s.due_date.date())
                    for s in sched_rows if s.type == "assignment"
                }
                for u in new_items:
                    due = parse_due_date(u.new_value, fallback_year)
                    if due is None:
                        continue
                    if sem_start is not None:
                        due = _snap_year_to_semester(due, sem_start)
                    title = (u.target_title or "과제").strip() or "과제"
                    key = (_norm_title(title), due.date())
                    if key in existing_assign:
                        continue  # 이미 같은 과제가 있음 — 재업로드 중복 방지.
                    existing_assign.add(key)
                    sched = Schedule(
                        course_id=course.id,
                        title=title,
                        type="assignment",
                        due_date=due,
                        description=(u.evidence or None),
                        is_auto=True,
                    )
                    session.add(sched)
                    await session.flush()  # schedule.id 확보 후 리마인더 todos 생성
                    for spec in build_auto_todos(sched):
                        session.add(Todo(**spec))
                    added_assignments += 1
                    logger.info(
                        "change_detect: file=%s 새 과제 자동추가 %r 마감=%s",
                        file_id, title, due.date(),
                    )
                if added_assignments:
                    await session.commit()

            # ----- (B) 기존 항목 변경은 pending 제안으로 (승인 후에만 반영) -----
            created = 0
            if change_items:
                existing = (
                    await session.execute(
                        select(SyllabusUpdateProposal).where(
                            SyllabusUpdateProposal.course_id == course.id,
                            SyllabusUpdateProposal.status == "pending",
                        )
                    )
                ).scalars().all()

                def _dedupe_key(field: str, value: str | None) -> tuple[str, str]:
                    return (field, " ".join((value or "").split()))

                seen = {_dedupe_key(p.field, p.new_value) for p in existing}
                for u in change_items:
                    key = _dedupe_key(u.field, u.new_value)
                    if key in seen:
                        continue
                    schedule_id = (
                        _match_schedule_id(u.target_title, sched_rows)
                        if u.field == "assignment_due" and u.target_title
                        else None
                    )
                    session.add(
                        SyllabusUpdateProposal(
                            course_id=course.id,
                            file_id=file_row.id,
                            schedule_id=schedule_id,
                            field=u.field,
                            target_title=u.target_title,
                            old_value=u.old_value,
                            new_value=u.new_value,
                            evidence=u.evidence,
                            confidence=round(u.confidence, 4),
                            status="pending",
                        )
                    )
                    seen.add(key)
                    created += 1
                if created:
                    await session.commit()

            logger.info(
                "change_detect: file=%s course=%s 새과제자동=%d 변경제안=%d",
                file_id, course.id, added_assignments, created,
            )


# ---------- Pipeline: summary generation ----------

async def _run_generate_summary(file_id: str, SessionLocal) -> None:
    from app.models.ai_content import AIContent
    from app.services.summarizer import SummarizerError, summarize_text

    async with SessionLocal() as session:
        file_row = await _load_file(session, UUID(file_id))
        if file_row is None:
            logger.warning("generate_summary: file %s not found", file_id)
            return
        if not file_row.extracted_text or not file_row.extracted_text.strip():
            logger.info("generate_summary: skip — no text for file=%s", file_id)
            return

        # 이미 요약이 있으면 재생성 안 함 (수동 재생성은 별도 엔드포인트로 처리).
        existing = (await session.execute(
            select(AIContent).where(
                AIContent.file_id == file_row.id,
                AIContent.content_type == "summary",
            ).order_by(AIContent.generated_at.desc())
        )).scalars().first()
        if existing is not None:
            logger.info("generate_summary: already exists for file=%s", file_id)
            return

        try:
            payload = await summarize_text(
                file_row.extracted_text,
                filename=file_row.filename,
            )
        except SummarizerError as exc:
            logger.warning("generate_summary: failed file=%s: %s", file_id, exc)
            return

        ac = AIContent(
            file_id=file_row.id,
            content_type="summary",
            content=payload,
        )
        session.add(ac)
        if not await _commit_or_skip_duplicate(session):
            return
        logger.info(
            "generate_summary: saved file=%s tokens=%s headline=%r",
            file_id, payload.get("tokens"), payload.get("headline", "")[:80],
        )


# ---------- Pipeline: 분석본 (학습 콘텐츠 공유 입력) ----------

async def _run_analyze_file(file_id: str, SessionLocal) -> None:
    """파일 텍스트 → 분석본 생성. 학습 콘텐츠 5종이 이 결과를 입력으로 재사용한다."""
    from app.models.ai_content import AIContent
    from app.services.analyzer import AnalyzerError, analyze_text

    async with SessionLocal() as session:
        file_row = await _load_file(session, UUID(file_id))
        if file_row is None or not (file_row.extracted_text or "").strip():
            logger.info("analyze_file: skip — file %s missing/empty", file_id)
            return

        existing = (await session.execute(
            select(AIContent).where(
                AIContent.file_id == file_row.id,
                AIContent.content_type == "analysis",
            ).order_by(AIContent.generated_at.desc())
        )).scalars().first()
        if existing is not None:
            logger.info("analyze_file: already exists file=%s", file_id)
            return

        try:
            payload = await analyze_text(
                file_row.extracted_text, filename=file_row.filename
            )
        except AnalyzerError as exc:
            logger.warning("analyze_file: failed file=%s: %s", file_id, exc)
            return

        ac = AIContent(
            file_id=file_row.id,
            content_type="analysis",
            scope="all",
            content=payload,
        )
        session.add(ac)
        if not await _commit_or_skip_duplicate(session):
            return
        logger.info(
            "analyze_file: saved file=%s tokens=%s concepts=%d terms=%d",
            file_id, payload.get("tokens"),
            len(payload.get("main_concepts", [])),
            len(payload.get("key_terms", [])),
        )

    # NOTE: 이전엔 분석본 저장 직후 quiz/flashcard/mindmap/memorize/topics 5종을 모두
    # 자동 큐잉했으나, Celery worker concurrency 가 한정적이라 사용자가 명시 클릭한
    # 작업이 뒤로 밀려 오히려 더 느리게 느껴짐. 분석본만 미리 만들어두고 학습 콘텐츠는
    # on-demand 로 생성 — 분석본 캐시 덕에 단발 호출은 5~7초로 빠르다.


# ---------- Pipeline: 학습 탭 AI 콘텐츠 생성 ----------

async def _run_generate_ai_content(
    file_id: str,
    content_type: str,
    scope: str,
    force: bool,
    requested_by_user_id: str | None,
    SessionLocal,
    *,
    exclude_questions: list[str] | None = None,
    instructions: str | None = None,
) -> None:
    """Celery 워커에서 실행되는 학습 콘텐츠 생성. 결과는 ai_contents 에 저장."""
    from app.models.ai_content import AIContent
    from app.services.content_generators import (
        ContentGeneratorError,
        GENERATOR_REGISTRY,
        generate_content,
        slice_text_by_pages,
    )

    if content_type not in GENERATOR_REGISTRY:
        logger.warning("generate_ai_content: unknown content_type=%s", content_type)
        return

    async with SessionLocal() as session:
        file_row = await _load_file(session, UUID(file_id))
        if file_row is None or not file_row.extracted_text:
            logger.info(
                "generate_ai_content: skip — file %s missing or empty text", file_id
            )
            return

        # 기존 결과 확인. force=False + exclude_questions/instructions 없음 일 때만
        # 캐시 hit 으로 스킵. '다른 문제로'(exclude_questions) 와 사용자 추가 지침
        # (instructions) 은 같은 캐시를 덮어쓰고 새로 만들어야 한다.
        existing = (await session.execute(
            select(AIContent).where(
                AIContent.file_id == file_row.id,
                AIContent.content_type == content_type,
                AIContent.scope == scope,
            ).order_by(AIContent.generated_at.desc())
        )).scalars().first()
        should_regenerate = force or bool(exclude_questions) or bool(instructions)
        if existing is not None and not should_regenerate:
            logger.info(
                "generate_ai_content: already exists file=%s type=%s scope=%s",
                file_id, content_type, scope,
            )
            return
        if existing is not None and should_regenerate:
            await session.execute(delete(AIContent).where(AIContent.id == existing.id))

        # scope 는 난이도가 인코딩된 복합 문자열일 수 있다(예: "all#hard", "1-3#hard").
        # 페이지 부분만 떼어 슬라이싱/분석본 판정에 쓰고, 난이도는 generator 로 넘긴다.
        # (난이도 없는 기존 scope = "all"/"1-3" 은 그대로 동작 — 기본 'easy'.)
        base_scope, _, _diff = scope.partition("#")
        difficulty = _diff or "easy"

        text = slice_text_by_pages(
            file_row.extracted_text, None if base_scope == "all" else base_scope
        )
        if not text.strip():
            logger.warning(
                "generate_ai_content: empty text after slicing file=%s scope=%s",
                file_id, scope,
            )
            return

        # 분석본(analysis) 가져오기 — 캐시 없으면 inline 으로 만들어 영구 캐시.
        # 분석본은 ~3000자 압축본이라 원문 18000자 대신 입력으로 쓰면 latency 50%+ 절감.
        # 페이지 범위 지정 시(base_scope != "all") 사용자가 부분 자료를 요청한 것이므로 원문 사용.
        analysis_payload: dict | None = None
        if base_scope == "all":
            analysis_row = (await session.execute(
                select(AIContent).where(
                    AIContent.file_id == file_row.id,
                    AIContent.content_type == "analysis",
                ).order_by(AIContent.generated_at.desc())
            )).scalars().first()
            if analysis_row is not None and isinstance(analysis_row.content, dict):
                analysis_payload = analysis_row.content
                logger.info(
                    "generate_ai_content: using cached analysis file=%s type=%s",
                    file_id, content_type,
                )
            else:
                # 분석본이 아직 없다 — analyze_file_task 가 큐에 있거나 안 돌았을 수 있음.
                # 다음에 올 quiz/flashcard 등을 위해 미리 만들어두면 후속 호출이 모두 빠름.
                logger.info(
                    "generate_ai_content: building analysis inline file=%s", file_id,
                )
                from app.services.analyzer import AnalyzerError, analyze_text
                try:
                    analysis_payload = await analyze_text(
                        file_row.extracted_text, filename=file_row.filename,
                    )
                    # 캐시에 저장 — 후속 generator 호출이 재사용.
                    inline_ac = AIContent(
                        file_id=file_row.id,
                        content_type="analysis",
                        scope="all",
                        content=analysis_payload,
                    )
                    session.add(inline_ac)
                    # 충돌(다른 워커가 분석본 먼저 저장)이어도 analysis_payload 는 메모리에
                    # 있으므로 그대로 입력으로 쓰고 진행한다 (return 하지 않음).
                    await _commit_or_skip_duplicate(session)
                    logger.info(
                        "generate_ai_content: inline analysis saved file=%s tokens=%s",
                        file_id, analysis_payload.get("tokens"),
                    )
                except AnalyzerError as exc:
                    logger.warning(
                        "generate_ai_content: inline analyze failed, falling back to raw text: %s",
                        exc,
                    )
                    analysis_payload = None

        try:
            payload = await generate_content(
                content_type, text, filename=file_row.filename,
                analysis=analysis_payload,
                exclude_questions=exclude_questions,
                difficulty=difficulty,
                instructions=instructions,
            )
        except ContentGeneratorError as exc:
            # 실패도 결과로 저장 — iOS 가 무한 폴링 안 하고 즉시 에러 화면 표시.
            # 사용자가 '다시 생성' 누르면 force=True 로 이 row 가 지워지고 재시도.
            logger.warning(
                "generate_ai_content: failed file=%s type=%s: %s",
                file_id, content_type, exc,
            )
            err_ac = AIContent(
                file_id=file_row.id,
                content_type=content_type,
                scope=scope,
                content={"error": str(exc)[:500]},
                requested_by_user_id=UUID(requested_by_user_id) if requested_by_user_id else None,
            )
            session.add(err_ac)
            # 에러 row 저장 중 충돌이면(다른 워커가 정상 결과를 이미 저장) 덮지 않는다.
            await _commit_or_skip_duplicate(session)
            return

        ac = AIContent(
            file_id=file_row.id,
            content_type=content_type,
            scope=scope,
            content=payload,
            requested_by_user_id=UUID(requested_by_user_id) if requested_by_user_id else None,
        )
        session.add(ac)
        if not await _commit_or_skip_duplicate(session):
            return
        logger.info(
            "generate_ai_content: saved file=%s type=%s scope=%s tokens=%s",
            file_id, content_type, scope, payload.get("tokens"),
        )
