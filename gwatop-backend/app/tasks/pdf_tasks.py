import asyncio
import logging
from typing import Optional

import fitz  # PyMuPDF
from sqlalchemy import select, update

from app.core.database import AsyncSessionLocal
from app.models.file import File
from app.services.s3 import download_object_bytes
from app.tasks.celery_app import celery_app

logger = logging.getLogger(__name__)

MAX_EXTRACTED_CHARS = 500_000


@celery_app.task(
    name="tasks.extract_pdf_text",
    bind=True,
    autoretry_for=(Exception,),
    retry_backoff=True,
    retry_backoff_max=300,
    retry_jitter=True,
    max_retries=3,
    acks_late=True,
)
def extract_pdf_text_task(self, file_id: str) -> dict:
    return asyncio.run(_run(file_id))


async def _run(file_id: str) -> dict:
    s3_key, filename = await _load_file_meta(file_id)
    if s3_key is None:
        return {"file_id": file_id, "status": "missing"}

    if not filename.lower().endswith(".pdf"):
        await _mark_skipped(file_id, reason="not_pdf")
        _enqueue_classify(file_id)
        return {"file_id": file_id, "status": "skipped_non_pdf"}

    await _set_status(file_id, "extracting")

    try:
        data = download_object_bytes(s3_key)
        text, pages = _extract_text(data)
    except Exception as exc:
        logger.exception("PDF extraction failed for file_id=%s", file_id)
        await _set_failure(file_id, str(exc)[:500])
        raise

    await _save_extracted(file_id, text, pages)
    _enqueue_classify(file_id)
    return {"file_id": file_id, "status": "extracted", "pages": pages, "chars": len(text)}


def _extract_text(data: bytes) -> tuple[str, int]:
    chunks: list[str] = []
    total_len = 0
    with fitz.open(stream=data, filetype="pdf") as doc:
        page_count = doc.page_count
        for page in doc:
            page_text = page.get_text("text") or ""
            if not page_text:
                continue
            remaining = MAX_EXTRACTED_CHARS - total_len
            if remaining <= 0:
                break
            if len(page_text) > remaining:
                page_text = page_text[:remaining]
            chunks.append(page_text)
            total_len += len(page_text)
    return "\n".join(chunks).strip(), page_count


async def _load_file_meta(file_id: str) -> tuple[Optional[str], str]:
    async with AsyncSessionLocal() as session:
        row = (
            await session.execute(
                select(File.s3_key, File.filename).where(File.id == file_id)
            )
        ).first()
    if row is None:
        return None, ""
    return row.s3_key, row.filename


async def _set_status(file_id: str, status: str) -> None:
    async with AsyncSessionLocal() as session:
        await session.execute(
            update(File).where(File.id == file_id).values(status=status)
        )
        await session.commit()


async def _save_extracted(file_id: str, text: str, pages: int) -> None:
    async with AsyncSessionLocal() as session:
        await session.execute(
            update(File)
            .where(File.id == file_id)
            .values(
                extracted_text=text,
                page_count=pages,
                status="extracted",
                extract_error=None,
            )
        )
        await session.commit()


async def _mark_skipped(file_id: str, reason: str) -> None:
    async with AsyncSessionLocal() as session:
        await session.execute(
            update(File)
            .where(File.id == file_id)
            .values(status="extracted", extract_error=reason)
        )
        await session.commit()


async def _set_failure(file_id: str, message: str) -> None:
    async with AsyncSessionLocal() as session:
        await session.execute(
            update(File)
            .where(File.id == file_id)
            .values(status="failed", extract_error=message)
        )
        await session.commit()


def _enqueue_classify(file_id: str) -> None:
    celery_app.send_task("tasks.classify_file", args=[file_id])
