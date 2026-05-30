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
import json
import logging
import re
from datetime import datetime, timedelta
from uuid import UUID

from sqlalchemy import select, delete
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.database import make_celery_session_factory
from app.models.course import Course
from app.models.file import File
from app.models.schedule import Schedule
from app.models.semester import Semester
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
from app.services.auto_classifier import detect_kind, guess_course_name
from app.services.course_matcher import CourseMatchError, match_or_create_course
from app.services.pdf_text import extract_tables_from_pdf, extract_text_from_pdf_bytes
from app.services.syllabus_parser import SyllabusParseError, parse_syllabus
from app.services.todo_generator import build_auto_todos
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
) -> None:
    """학습 탭의 quiz/flashcard/mindmap/memorize/topics 생성 작업.

    iOS의 generate POST 호출은 이 태스크를 큐잉만 하고 즉시 202 반환한다.
    실제 GPT 호출은 워커에서 진행되어 사용자가 다른 탭으로 이동해도 결과가 안전하게 저장됨.

    `exclude_questions` 는 퀴즈 전용 — 이전에 사용자가 풀었던 문제 텍스트 리스트.
    있으면 force=True 처럼 동작하면서 GPT 에 '이 문제들과 다르게 출제' 를 지시한다.
    """
    _run_with_fresh_engine(
        lambda Session: _run_generate_ai_content(
            file_id, content_type, scope, force, requested_by_user_id, Session,
            exclude_questions=exclude_questions,
        )
    )


# notify_classified 는 Day 7 이후 app/tasks/notify_tasks.py 로 이관됨.
# 호출은 .delay(...)로 같은 이름 ("tasks.notify_classified")으로 발송하므로 변경 없음.

# ---------- Pipeline: text extraction ----------

async def _run_extract(file_id: str, SessionLocal) -> None:
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

        file_row.status = "processing"
        file_row.parse_error = None
        await session.commit()

        try:
            data = await asyncio.to_thread(s3.download_to_bytes, file_row.s3_key)
        except Exception as exc:
            logger.exception("extract_text: S3 download failed for %s", file_id)
            await _mark_failed(session, file_row, f"S3 download failed: {exc}")
            return

        text: str | None = None
        if file_row.file_type == "pdf":
            try:
                text = await asyncio.to_thread(extract_text_from_pdf_bytes, data)
            except Exception as exc:
                logger.exception("extract_text: PyMuPDF failed for %s", file_id)
                await _mark_failed(session, file_row, f"PDF text extraction failed: {exc}")
                return

            # OCR fallback — PyMuPDF 가 거의 빈 결과를 돌려준 경우 (손글씨/스캔 PDF).
            # gpt-4o-mini vision 으로 페이지별 OCR 실행.
            from app.services.ocr_fallback import needs_ocr, ocr_pdf, OCRError
            if needs_ocr(text):
                logger.info(
                    "extract_text: triggering OCR fallback for file=%s (got %d chars from PyMuPDF)",
                    file_id, len(text or ""),
                )
                try:
                    ocr_text = await ocr_pdf(data)
                    if ocr_text and len(ocr_text.strip()) > len(text or ""):
                        text = ocr_text
                        logger.info(
                            "extract_text: OCR fallback succeeded file=%s chars=%d",
                            file_id, len(ocr_text),
                        )
                except OCRError as exc:
                    logger.warning(
                        "extract_text: OCR fallback failed file=%s: %s", file_id, exc,
                    )
                    # 원래 text 유지하고 계속 진행 (빈 문자열일 수도)

        file_row.extracted_text = text
        # 강의계획서인데 텍스트가 비어 있으면(=PyMuPDF가 빈 결과 반환) parse를 트리거할 수 없다.
        # 그대로 'extracted' 로 두면 사용자가 영원히 "처리 중"으로 보게 되니 명시적으로 실패 처리.
        if file_row.is_syllabus and not (text and text.strip()):
            await _mark_failed(
                session, file_row,
                "강의계획서에서 텍스트를 추출하지 못했어요. PDF가 이미지로만 이루어져 있는지 확인해 주세요.",
            )
            return

        file_row.status = "extracted"
        await session.commit()

        text_preview = (text or "").strip().replace("\n", " ")[:200]
        logger.info(
            "extract_text: file=%s chars=%d preview=%r",
            file_id, len(text or ""), text_preview,
        )

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
    학기가 하나도 없으면 명확한 메시지로 실패 처리.
    """
    async with SessionLocal() as session:
        file_row = await _load_file(session, UUID(file_id))
        if file_row is None:
            return

        text = file_row.extracted_text or ""
        decision = await detect_kind(text, file_row.filename)
        logger.info(
            "auto_dispatch: file=%s kind=%s confidence=%.2f reason=%s",
            file_id, decision.kind, decision.confidence, decision.reason,
        )

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

        # material — 과목 자동 매칭 또는 신규 생성.
        user = await session.get(User, file_row.uploaded_by_user_id) if file_row.uploaded_by_user_id else None
        if user is None:
            await _mark_failed(session, file_row, "업로드 사용자 정보를 찾을 수 없어요.")
            return

        course_name = await guess_course_name(text, file_row.filename)
        try:
            course, _semester, created = await match_or_create_course(
                session, user, course_name,
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
            "auto_dispatch: file=%s material → course=%s (%s, created=%s)",
            file_id, course.id, course.name, created,
        )
        classify_file_task.delay(file_id)


# ---------- Pipeline: syllabus parsing ----------

async def _run_parse_syllabus(file_id: str, SessionLocal) -> None:
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
        # 먼저 그 schedules에 매달린 auto todos를 같이 지운다 (FK ondelete=SET NULL이라
        # schedule만 지우면 orphaned auto todo가 남는다).
        await session.execute(
            delete(Todo).where(
                Todo.is_auto.is_(True),
                Todo.schedule_id.in_(
                    select(Schedule.id).where(
                        Schedule.course_id == course.id,
                        Schedule.is_auto.is_(True),
                    )
                ),
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

        inserted_rows = _insert_schedules(session, course.id, syllabus, semester.start_date)

        # schedule.id 확보를 위해 flush 후 auto todos 생성 (시험 D-14/7/3/1, 과제 D-7/3/1)
        await session.flush()
        todos_added = 0
        for sched in inserted_rows:
            for spec in build_auto_todos(sched):
                session.add(Todo(**spec))
                todos_added += 1
        logger.info(
            "[PARSE_DEBUG] generated %d auto todos for %d schedules",
            todos_added, len(inserted_rows),
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
) -> list[Schedule]:
    """파싱된 시험/과제 일정을 schedules 테이블에 자동 등록.

    날짜 매핑 우선순위:
      1) exam_date / due_date 가 명시되어 있으면 그대로
      2) 없으면 제목·노트에서 'N주차' 추출 → semester_start + (N-1)*7
      3) 그래도 없으면 'exam'은 weeks 배열에서 '중간/기말' 키워드 매칭으로 추정
      4) 다 실패하면 스킵

    is_auto=True로 마킹.
    """
    inserted: list[Schedule] = []

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
            logger.warning("[PARSE_DEBUG] SKIP exam %r — no date (source=%s)", exam.title, source)
            continue

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
            logger.warning("[PARSE_DEBUG] SKIP assignment %r — no date (source=%s)", assignment.title, source)
            continue

        row = _schedule_from_assignment(course_id, assignment, due)
        session.add(row)
        inserted.append(row)
        logger.info("[PARSE_DEBUG] ADD assignment %r at %s (source=%s)", assignment.title, due.isoformat(), source)

    return inserted


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

        week_embeddings = deserialize_week_embeddings(
            course.weekly_topic_embeddings or []
        )

        # OpenAI 호출이 실패해도 task 자체는 죽지 않도록 wrap. classify_by_embedding 은
        # 내부에서 EmbeddingClassifierError를 swallow하지만, 다른 경로에서 raw OpenAIError가
        # 새는 것을 대비한 안전망.
        try:
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

    # 분류 결과와 무관하게 알림은 한 번 — UI에서 "미분류 폴더" 안내에도 쓰임.
    # notify_classified 태스크는 app/tasks/notify_tasks.py 로 이관됨. 이름 기반으로
    # send_task 호출 (import 회피).
    celery_app.send_task("tasks.notify_classified", args=[file_id])

    # 학습 탭 진입 전에 미리 요약 + 분석본을 만들어둔다.
    # 분석본은 quiz/flashcard/mindmap/memorize/topics 의 공유 입력으로 재활용.
    if file_row.extracted_text and file_row.extracted_text.strip():
        generate_summary_task.delay(file_id)
        analyze_file_task.delay(file_id)


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

        # 기존 결과 확인. force=False + exclude_questions 없음 일 때만 캐시 hit 으로 스킵.
        # '다른 문제로' 옵션(exclude_questions) 은 같은 캐시를 덮어쓰고 새로 만들어야 한다.
        existing = (await session.execute(
            select(AIContent).where(
                AIContent.file_id == file_row.id,
                AIContent.content_type == content_type,
                AIContent.scope == scope,
            ).order_by(AIContent.generated_at.desc())
        )).scalars().first()
        should_regenerate = force or bool(exclude_questions)
        if existing is not None and not should_regenerate:
            logger.info(
                "generate_ai_content: already exists file=%s type=%s scope=%s",
                file_id, content_type, scope,
            )
            return
        if existing is not None and should_regenerate:
            await session.execute(delete(AIContent).where(AIContent.id == existing.id))

        text = slice_text_by_pages(
            file_row.extracted_text, None if scope == "all" else scope
        )
        if not text.strip():
            logger.warning(
                "generate_ai_content: empty text after slicing file=%s scope=%s",
                file_id, scope,
            )
            return

        # 분석본(analysis) 가져오기 — 캐시 없으면 inline 으로 만들어 영구 캐시.
        # 분석본은 ~3000자 압축본이라 원문 18000자 대신 입력으로 쓰면 latency 50%+ 절감.
        # 페이지 범위 지정 시(scope != "all") 사용자가 부분 자료를 요청한 것이므로 원문 사용.
        analysis_payload: dict | None = None
        if scope == "all":
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
