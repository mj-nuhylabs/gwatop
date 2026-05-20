import uuid
from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select

from app.core.database import get_db
from app.api.v1.dependencies import get_current_user
from app.models.user import User
from app.models.course import Course
from app.models.semester import Semester
from app.models.file import File
from app.schemas.file import PresignedUrlRequest, PresignedUrlResponse, FileResponse, FileConfirmResponse
from app.services import s3
from app.tasks.file_tasks import extract_text_task

router = APIRouter(tags=["Files"])

CONTENT_TYPES = {
    "pdf": "application/pdf",
    "pptx": "application/vnd.openxmlformats-officedocument.presentationml.presentation",
    "docx": "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
    "image": "image/jpeg",
    "other": "application/octet-stream",
}


async def _owned_course(course_id: uuid.UUID, user: User, db: AsyncSession) -> Course:
    result = await db.execute(
        select(Course)
        .join(Semester, Course.semester_id == Semester.id)
        .where(Course.id == course_id, Semester.user_id == user.id)
    )
    course = result.scalar_one_or_none()
    if not course:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Course not found")
    return course


@router.post("/courses/{course_id}/files/presigned-url", response_model=PresignedUrlResponse, status_code=status.HTTP_201_CREATED)
async def get_presigned_url(
    course_id: uuid.UUID,
    body: PresignedUrlRequest,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    await _owned_course(course_id, current_user, db)

    storage_key = s3.build_storage_key(str(current_user.id), body.filename)
    content_type = CONTENT_TYPES.get(body.file_type, "application/octet-stream")

    try:
        upload_url = s3.generate_presigned_put_url(storage_key, content_type)
    except Exception:
        raise HTTPException(status_code=status.HTTP_503_SERVICE_UNAVAILABLE, detail="Failed to generate upload URL")

    file_record = File(
        course_id=course_id,
        filename=body.filename,
        file_type=body.file_type,
        s3_key=storage_key,
        size_bytes=body.file_size_bytes,
        is_syllabus=body.is_syllabus,
        status="pending",
    )
    db.add(file_record)
    await db.commit()
    await db.refresh(file_record)

    return PresignedUrlResponse(
        upload_url=upload_url,
        storage_key=storage_key,
        file_id=file_record.id,
    )


@router.post("/courses/{course_id}/files/{file_id}/confirm", response_model=FileConfirmResponse)
async def confirm_upload(
    course_id: uuid.UUID,
    file_id: uuid.UUID,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    await _owned_course(course_id, current_user, db)

    result = await db.execute(
        select(File).where(File.id == file_id, File.course_id == course_id)
    )
    file_record = result.scalar_one_or_none()
    if not file_record:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="File not found")

    extract_text_task.delay(str(file_id))

    return FileConfirmResponse(file=FileResponse.model_validate(file_record))


@router.get("/courses/{course_id}/files", response_model=list[FileResponse])
async def list_files(
    course_id: uuid.UUID,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    await _owned_course(course_id, current_user, db)
    result = await db.execute(
        select(File).where(File.course_id == course_id).order_by(File.created_at.desc())
    )
    return result.scalars().all()
