"""파일 업로드 후처리 Celery 파이프라인.

extract_text_task:
    files.s3_key 다운로드 → (PDF면) PyMuPDF로 텍스트 추출 → files.extracted_text 저장.
    is_syllabus=True 이면 parse_syllabus_task 자동 트리거.

parse_syllabus_task:
    files.extracted_text + course/semester 컨텍스트 → GPT-4o-mini 파싱 →
    schedules 테이블에 시험/과제 일정 자동 INSERT.
"""

from __future__ import annotations

import asyncio
import logging
from datetime import datetime
from uuid import UUID

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.database import AsyncSessionLocal
from app.models.course import Course
from app.models.file import File
from app.models.schedule import Schedule
from app.models.semester import Semester
from app.schemas.syllabus import ParsedAssignment, ParsedExam, ParsedSyllabus
from app.services import s3
from app.services.pdf_text import extract_text_from_pdf_bytes
from app.services.syllabus_parser import SyllabusParseError, parse_syllabus
from app.tasks.celery_app import celery_app

logger = logging.getLogger(__name__)


# ---------- Celery entry points ----------

@celery_app.task(name="tasks.extract_text")
def extract_text_task(file_id: str) -> None:
    asyncio.run(_run_extract(file_id))


@celery_app.task(name="tasks.parse_syllabus")
def parse_syllabus_task(file_id: str) -> None:
    asyncio.run(_run_parse_syllabus(file_id))


# ---------- Pipeline: text extraction ----------

async def _run_extract(file_id: str) -> None:
    async with AsyncSessionLocal() as session:
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

    if file_row.is_syllabus and text:
        parse_syllabus_task.delay(file_id)


# ---------- Pipeline: syllabus parsing ----------

async def _run_parse_syllabus(file_id: str) -> None:
    async with AsyncSessionLocal() as session:
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

        inserted = _insert_schedules(session, course.id, result.syllabus)
        file_row.status = "parsed"
        file_row.ai_confidence = result.syllabus.confidence
        await session.commit()

        logger.info(
            "parse_syllabus: file=%s course=%s schedules_inserted=%d confidence=%.2f tokens=%d",
            file_id, course.id, inserted, result.syllabus.confidence, result.usage.total_tokens,
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


def _insert_schedules(session: AsyncSession, course_id: UUID, syllabus: ParsedSyllabus) -> int:
    """파싱된 시험/과제 일정을 schedules 테이블에 자동 등록.

    is_auto=True로 마킹하여 사용자 수동 추가와 구분.
    날짜 없는 항목은 스킵.
    """
    count = 0

    for exam in syllabus.exams:
        due = _to_datetime(exam.exam_date, exam.start_time)
        if due is None:
            continue
        session.add(_schedule_from_exam(course_id, exam, due))
        count += 1

    for assignment in syllabus.assignments:
        due = _to_datetime(assignment.due_date)
        if due is None:
            continue
        session.add(_schedule_from_assignment(course_id, assignment, due))
        count += 1

    return count


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
