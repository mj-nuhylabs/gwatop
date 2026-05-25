import logging
import uuid
from fastapi import APIRouter, Depends, HTTPException, status
from pydantic import BaseModel, Field
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select

from app.core.config import settings
from app.core.database import get_db
from app.api.v1.dependencies import get_current_user
from app.api.v1.deps_owned import owned_course, owned_file
from app.models.user import User
from app.models.course import Course
from app.models.semester import Semester
from app.models.file import File
from app.schemas.file import PresignedUrlRequest, PresignedUrlResponse, FileResponse, FileConfirmResponse
from app.services import s3
from app.tasks.file_tasks import classify_file_task, extract_text_task

logger = logging.getLogger(__name__)

router = APIRouter(tags=["Files"])

CONTENT_TYPES = {
    "pdf": "application/pdf",
    "pptx": "application/vnd.openxmlformats-officedocument.presentationml.presentation",
    "docx": "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
    "image": "image/jpeg",
    "other": "application/octet-stream",
}


def _validate_upload(body: PresignedUrlRequest) -> None:
    """업로드 정책 검증 — 크기 상한 + file_type 화이트리스트.

    presigned URL을 받으면 S3에 임의 사이즈를 PUT 할 수 있게 되므로,
    URL 발급 단계에서 미리 거부한다(완벽한 방어는 아니지만 일반 사용자 보호).
    """
    if body.file_size_bytes <= 0:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="file_size_bytes must be > 0",
        )
    if body.file_size_bytes > settings.MAX_UPLOAD_BYTES:
        max_mb = settings.MAX_UPLOAD_BYTES // (1024 * 1024)
        raise HTTPException(
            status_code=status.HTTP_413_REQUEST_ENTITY_TOO_LARGE,
            detail=f"파일 크기가 너무 큽니다. 최대 {max_mb}MB까지 업로드할 수 있어요.",
        )
    allowed = settings.allowed_file_types_set
    if body.file_type not in allowed:
        raise HTTPException(
            status_code=status.HTTP_415_UNSUPPORTED_MEDIA_TYPE,
            detail=f"지원하지 않는 파일 형식입니다. 허용: {sorted(allowed)}",
        )


@router.post("/courses/{course_id}/files/presigned-url", response_model=PresignedUrlResponse, status_code=status.HTTP_201_CREATED)
async def get_presigned_url(
    course_id: uuid.UUID,
    body: PresignedUrlRequest,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    await owned_course(course_id, current_user, db)
    _validate_upload(body)

    storage_key = s3.build_storage_key(str(current_user.id), body.filename)
    content_type = CONTENT_TYPES.get(body.file_type, "application/octet-stream")

    try:
        upload_url = s3.generate_presigned_put_url(storage_key, content_type)
    except Exception:
        logger.exception("presigned URL 발급 실패 user=%s course=%s", current_user.id, course_id)
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
    await owned_course(course_id, current_user, db)

    result = await db.execute(
        select(File).where(File.id == file_id, File.course_id == course_id)
    )
    file_record = result.scalar_one_or_none()
    if not file_record:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="File not found")

    extract_text_task.delay(str(file_id))

    return FileConfirmResponse(file=FileResponse.model_validate(file_record))


# ---------- 강의계획서 전용 업로드 (과목 미선택) ----------
# 사용자는 과목을 모르고도 syllabus PDF만 업로드할 수 있다. 백엔드는 파싱이 끝난 뒤
# 파싱 결과의 강의명으로 (1) active semester 안 같은 이름 course에 매칭하거나
# (2) 없으면 새 course를 자동 생성한 다음 file.course_id 를 채운다.


@router.post(
    "/files/syllabus/presigned-url",
    response_model=PresignedUrlResponse,
    status_code=status.HTTP_201_CREATED,
)
async def get_syllabus_presigned_url(
    body: PresignedUrlRequest,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """과목 선택 없이 강의계획서 업로드용 presigned URL 발급.

    file row의 course_id는 NULL 상태로 만들어지고, parse 단계에서 자동 결정된다.
    is_syllabus 는 항상 True로 강제 (이 경로는 syllabus 전용).
    """
    _validate_upload(body)

    storage_key = s3.build_storage_key(str(current_user.id), body.filename)
    content_type = CONTENT_TYPES.get(body.file_type, "application/octet-stream")

    try:
        upload_url = s3.generate_presigned_put_url(storage_key, content_type)
    except Exception:
        logger.exception("presigned URL 발급 실패 (syllabus) user=%s", current_user.id)
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="Failed to generate upload URL",
        )

    file_record = File(
        course_id=None,
        uploaded_by_user_id=current_user.id,
        filename=body.filename,
        file_type=body.file_type,
        s3_key=storage_key,
        size_bytes=body.file_size_bytes,
        is_syllabus=True,
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


@router.post(
    "/files/syllabus/{file_id}/confirm",
    response_model=FileConfirmResponse,
)
async def confirm_syllabus_upload(
    file_id: uuid.UUID,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """syllabus 업로드(과목 미선택) 후 S3 업로드 완료 신호. parse 트리거."""
    file_record, _ = await owned_file(file_id, current_user, db)
    if not file_record.is_syllabus:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="이 엔드포인트는 강의계획서 전용입니다. /v1/courses/.../confirm 을 사용하세요.",
        )

    extract_text_task.delay(str(file_id))
    return FileConfirmResponse(file=FileResponse.model_validate(file_record))


@router.get("/courses/{course_id}/files", response_model=list[FileResponse])
async def list_files(
    course_id: uuid.UUID,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    await owned_course(course_id, current_user, db)
    result = await db.execute(
        select(File).where(File.course_id == course_id).order_by(File.created_at.desc())
    )
    return result.scalars().all()


@router.get("/files/{file_id}/debug")
async def file_debug(
    file_id: uuid.UUID,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """업로드된 파일의 처리 상태 + 생성된 schedules + 추출 텍스트 미리보기를
    한 번에 돌려준다. iOS GwaTopFileNoteView가 사용한다.

    소유권은 owned_file로 검증되므로 다른 사용자의 파일은 못 본다.
    TODO(P2): 이름이 'debug'라 오해 소지가 있음 — 향후 /v1/files/{id} 로 이름 변경하고
              iOS 클라이언트도 함께 마이그레이션.
    """
    from app.models.schedule import Schedule

    file_row, course = await owned_file(file_id, current_user, db)

    # course가 아직 결정되지 않은 강의계획서(파싱 중)는 schedules도 없음.
    schedules = []
    if file_row.course_id is not None:
        schedules_q = await db.execute(
            select(Schedule)
            .where(Schedule.course_id == file_row.course_id, Schedule.is_auto.is_(True))
            .order_by(Schedule.created_at.desc())
            .limit(50)
        )
        schedules = schedules_q.scalars().all()

    text = file_row.extracted_text or ""
    course_block: dict | None = None
    if course is not None:
        weekly_topics = course.weekly_topics or []
        course_block = {
            "id": str(course.id),
            "name": course.name,
            "weekly_topics_count": len(weekly_topics),
            "weekly_topics_preview": weekly_topics[:3],
            "has_week_embeddings": bool(course.weekly_topic_embeddings),
        }

    return {
        "file": {
            "id": str(file_row.id),
            "filename": file_row.filename,
            "status": file_row.status,
            "is_syllabus": file_row.is_syllabus,
            "course_id": str(file_row.course_id) if file_row.course_id else None,
            "week": file_row.week,
            "ai_confidence": file_row.ai_confidence,
            "classification_source": file_row.classification_source,
            "parse_error": file_row.parse_error,
            "extracted_text_length": len(text),
            "extracted_text_preview": text[:500].replace("\n", " "),
            "created_at": file_row.created_at.isoformat(),
            "updated_at": file_row.updated_at.isoformat(),
        },
        "course": course_block,
        "schedules_auto": [
            {
                "id": str(s.id),
                "title": s.title,
                "type": s.type,
                "due_date": s.due_date.isoformat(),
                "description": s.description,
                "created_at": s.created_at.isoformat(),
            }
            for s in schedules
        ],
        "schedules_count": len(schedules),
    }


# ---------- Day 4: 자동 분류 결과 조회/수동 정정 ----------


@router.post("/files/{file_id}/reclassify", status_code=status.HTTP_202_ACCEPTED)
async def reclassify_file(
    file_id: uuid.UUID,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """자동 분류를 다시 실행한다. 강의계획서가 새로 파싱되어 임베딩 캐시가
    갱신된 경우, 또는 분류 결과가 부정확할 때 사용한다."""
    file_row, _ = await owned_file(file_id, current_user, db)
    if file_row.is_syllabus:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="강의계획서는 자동 분류 대상이 아닙니다.",
        )

    classify_file_task.delay(str(file_id))
    return {"file_id": str(file_id), "status": "queued"}


class ManualWeekUpdate(BaseModel):
    week: int | None = Field(None, ge=1, le=30)


@router.patch("/files/{file_id}/week", response_model=FileResponse)
async def set_file_week(
    file_id: uuid.UUID,
    body: ManualWeekUpdate,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """사용자가 분류 결과를 수동으로 정정/지정한다.

    body.week=null 이면 미분류로 되돌린다.
    """
    file_row, _ = await owned_file(file_id, current_user, db)

    file_row.week = body.week
    if body.week is None:
        file_row.classification_source = None
        file_row.status = "unclassified"
        file_row.ai_confidence = 0.0
    else:
        file_row.classification_source = "manual"
        file_row.status = "classified"
        file_row.ai_confidence = 1.0

    await db.commit()
    await db.refresh(file_row)
    return FileResponse.model_validate(file_row)
