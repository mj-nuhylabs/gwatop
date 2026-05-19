import asyncio
from sqlalchemy import update

from app.tasks.celery_app import celery_app
from app.core.database import AsyncSessionLocal
from app.models.file import File


@celery_app.task(name="tasks.classify_file")
def classify_file_task(file_id: str):
    asyncio.run(_mark_processing(file_id))


async def _mark_processing(file_id: str):
    async with AsyncSessionLocal() as session:
        await session.execute(
            update(File).where(File.id == file_id).values(status="processing")
        )
        await session.commit()
