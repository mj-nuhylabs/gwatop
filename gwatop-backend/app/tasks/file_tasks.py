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
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.database import make_celery_session_factory
from app.models.course import Course
from app.models.file import File
from app.models.schedule import Schedule
from app.models.semester import Semester
from app.models.todo import Todo
from app.schemas.syllabus import ParsedAssignment, ParsedExam, ParsedSyllabus, ParsedWeek
from app.services import s3
from app.services.classification import classify_file
from app.services.embedding_classifier import (
    EmbeddingClassifierError,
    build_weekly_topic_embeddings,
    deserialize_week_embeddings,
    serialize_week_embeddings,
)
from app.services.pdf_text import extract_text_from_pdf_bytes
from app.services.syllabus_parser import SyllabusParseError, parse_syllabus
from app.services.todo_generator import build_auto_todos
from app.tasks.celery_app import celery_app

logger = logging.getLogger(__name__)


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


@celery_app.task(name="tasks.notify_classified")
def notify_classified_task(file_id: str) -> None:
    """분류 완료 알림 placeholder.

    Day 7에서 APNs로 실제 푸시를 보내도록 교체한다. 지금은 로그만.
    """
    logger.info("notify_classified: file=%s (APNs not wired yet)", file_id)


# ---------- Pipeline: text extraction ----------

async def _run_extract(file_id: str, SessionLocal) -> None:
    async with SessionLocal() as session:
        file_row = await _load_file(session, UUID(file_id))
        if file_row is None:
            logger.warning("extract_text: file %s not found", file_id)
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

        file_row.extracted_text = text
        file_row.status = "extracted"
        await session.commit()

        text_preview = (text or "").strip().replace("\n", " ")[:200]
        logger.info(
            "extract_text: file=%s chars=%d preview=%r",
            file_id, len(text or ""), text_preview,
        )

    if file_row.is_syllabus and text:
        parse_syllabus_task.delay(file_id)
    elif not file_row.is_syllabus:
        # Day 4: 일반 강의 자료는 주차 자동 분류 파이프라인으로 넘긴다.
        # PDF가 아니어서 text가 None이어도 파일명 regex만으로 분류 시도할 수 있다.
        classify_file_task.delay(file_id)


# ---------- Pipeline: syllabus parsing ----------

async def _run_parse_syllabus(file_id: str, SessionLocal) -> None:
    async with SessionLocal() as session:
        file_row = await _load_file(session, UUID(file_id))
        if file_row is None:
            logger.warning("parse_syllabus: file %s not found", file_id)
            return

        if not file_row.extracted_text:
            await _mark_failed(session, file_row, "No extracted_text to parse")
            return

        course = await session.get(Course, file_row.course_id)
        if course is None:
            await _mark_failed(session, file_row, "Course not found")
            return
        semester = await session.get(Semester, course.semester_id)
        if semester is None:
            await _mark_failed(session, file_row, "Semester not found")
            return

        year, term = _derive_year_term(semester)
        file_row.status = "parsing"
        await session.commit()

        try:
            result = await parse_syllabus(file_row.extracted_text, year=year, term=term)
        except SyllabusParseError as exc:
            logger.exception("parse_syllabus failed for %s", file_id)
            await _mark_failed(session, file_row, f"Syllabus parse failed: {exc}")
            return

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

        # Day 4: 주차별 토픽을 Course에 캐시. 자료 자동 분류의 기준 데이터가 된다.
        course.weekly_topics = [
            {"week_number": w.week_number, "topic": w.topic, "notes": w.notes}
            for w in syllabus.weeks
        ]
        # 임베딩 캐시 빌드. OpenAI 호출 실패해도 syllabus 파싱 자체는 성공으로 본다.
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

        course = await session.get(Course, file_row.course_id)
        if course is None:
            await _mark_failed(session, file_row, "Course not found")
            return

        file_row.status = "classifying"
        await session.commit()

        week_embeddings = deserialize_week_embeddings(
            course.weekly_topic_embeddings or []
        )

        result = await classify_file(
            filename=file_row.filename or "",
            extracted_text=file_row.extracted_text,
            week_embeddings=week_embeddings,
        )

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
    notify_classified_task.delay(file_id)
