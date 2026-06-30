import asyncio
import logging
import uuid
from fastapi import APIRouter, Depends, HTTPException, status
from pydantic import BaseModel, Field
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select, or_, delete, update

from app.core.config import settings
from app.core.database import get_db
from app.api.v1.dependencies import get_current_user
from app.api.v1.deps_owned import owned_course, owned_file
from app.models.user import User
from app.models.course import Course
from app.models.semester import Semester
from app.models.file import File
from app.models.schedule import Schedule
from app.models.todo import Todo
from app.schemas.file import (
    PresignedUrlRequest,
    PresignedUrlResponse,
    FileResponse,
    FileConfirmResponse,
    YouTubeUploadRequest,
)
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


def _verify_uploaded_object(file_record: File) -> None:
    """S3 업로드 완료 후 실제 객체 크기/Content-Type을 재검증한다."""
    try:
        meta = s3.head_object(file_record.s3_key)
    except Exception:
        logger.exception("S3 object head 실패 file=%s key=%s", file_record.id, file_record.s3_key)
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="업로드된 파일을 확인할 수 없어요. 업로드를 다시 시도해 주세요.",
        )

    size = int(meta.get("ContentLength") or 0)
    if size <= 0:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="업로드된 파일이 비어 있어요.")
    if size > settings.MAX_UPLOAD_BYTES:
        raise HTTPException(status_code=status.HTTP_413_REQUEST_ENTITY_TOO_LARGE, detail="업로드된 파일이 허용 크기를 초과했어요.")
    if file_record.size_bytes is not None and size != file_record.size_bytes:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="업로드된 파일 크기가 요청 정보와 일치하지 않아요.")

    expected = CONTENT_TYPES.get(file_record.file_type)
    actual = (meta.get("ContentType") or "").split(";", 1)[0].strip().lower()
    if expected and actual and actual != expected.lower():
        raise HTTPException(status_code=status.HTTP_415_UNSUPPORTED_MEDIA_TYPE, detail="업로드된 파일 형식이 요청 정보와 일치하지 않아요.")


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

    # 멱등성: status 는 pending(생성) → processing → extracted → ... 로만 전진한다.
    # 아직 추출 전(pending/uploading)일 때만 트리거하고, 이미 처리 단계로 넘어간 파일은
    # 재트리거하지 않는다 (중복 confirm 으로 동일 S3 객체를 다시 다운로드·추출하는 낭비 방지).
    # ⚠️ presigned-url 생성 시 초기 status 는 "pending" — "uploading" 만 보면 일반 자료가
    #    영영 추출되지 않으니 둘 다 포함해야 한다.
    if file_record.status in ("pending", "uploading"):
        _verify_uploaded_object(file_record)
        extract_text_task.delay(str(file_id))

    return FileConfirmResponse(file=FileResponse.model_validate(file_record))


# ---------- 멀티파트 업로드 (대용량 파일) ----------
# 단일 PUT 으로 수십~수백 MB 를 올리면 전송 중 연결이 끊겨 통째로 실패한다.
# 파일 행은 기존 presigned-url 엔드포인트로 먼저 만들고(= s3_key 확보), 그 file_id 에 대해
# 아래 3단계로 파트 업로드한다. course/syllabus/auto 모두 owned_file 로 검증되어 공용이다.
#   1) create   → S3 멀티파트 시작, upload_id + 권장 part_size 반환
#   2) part-url → 각 파트 PUT 용 presigned URL (파트마다 호출)
#   3) complete → 파트 ETag 들을 합쳐 객체 확정 + 기존 confirm 과 동일하게 검증/추출 큐잉

# 파트 크기 10MB — S3 최소(5MB, 마지막 파트 예외) 이상이고, 150MB 도 15파트면 충분.
MULTIPART_PART_SIZE = 10 * 1024 * 1024


class MultipartCreateResponse(BaseModel):
    upload_id: str
    storage_key: str
    part_size: int


class MultipartPartUrlRequest(BaseModel):
    upload_id: str
    part_number: int = Field(ge=1, le=10000)


class MultipartPartUrlResponse(BaseModel):
    url: str


class MultipartCompletePart(BaseModel):
    part_number: int = Field(ge=1, le=10000)
    etag: str


class MultipartCompleteRequest(BaseModel):
    upload_id: str
    parts: list[MultipartCompletePart] = Field(min_length=1)


@router.post(
    "/files/{file_id}/multipart/create",
    response_model=MultipartCreateResponse,
    status_code=status.HTTP_201_CREATED,
)
async def create_multipart(
    file_id: uuid.UUID,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    file_record, _ = await owned_file(file_id, current_user, db)
    if not file_record.s3_key:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="S3 업로드 대상 파일이 아니에요.")

    content_type = CONTENT_TYPES.get(file_record.file_type, "application/octet-stream")
    try:
        upload_id = s3.create_multipart_upload(file_record.s3_key, content_type)
    except Exception:
        logger.exception("멀티파트 시작 실패 file=%s key=%s", file_record.id, file_record.s3_key)
        raise HTTPException(status_code=status.HTTP_503_SERVICE_UNAVAILABLE, detail="Failed to start multipart upload")

    return MultipartCreateResponse(
        upload_id=upload_id,
        storage_key=file_record.s3_key,
        part_size=MULTIPART_PART_SIZE,
    )


@router.post(
    "/files/{file_id}/multipart/part-url",
    response_model=MultipartPartUrlResponse,
)
async def multipart_part_url(
    file_id: uuid.UUID,
    body: MultipartPartUrlRequest,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    file_record, _ = await owned_file(file_id, current_user, db)
    if not file_record.s3_key:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="S3 업로드 대상 파일이 아니에요.")
    try:
        url = s3.generate_presigned_upload_part_url(
            file_record.s3_key, body.upload_id, body.part_number
        )
    except Exception:
        logger.exception("파트 URL 발급 실패 file=%s part=%s", file_record.id, body.part_number)
        raise HTTPException(status_code=status.HTTP_503_SERVICE_UNAVAILABLE, detail="Failed to generate part URL")
    return MultipartPartUrlResponse(url=url)


@router.post(
    "/files/{file_id}/multipart/complete",
    response_model=FileConfirmResponse,
)
async def complete_multipart(
    file_id: uuid.UUID,
    body: MultipartCompleteRequest,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    file_record, _ = await owned_file(file_id, current_user, db)
    if not file_record.s3_key:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="S3 업로드 대상 파일이 아니에요.")

    parts = sorted(
        ({"PartNumber": p.part_number, "ETag": p.etag} for p in body.parts),
        key=lambda x: x["PartNumber"],
    )
    try:
        s3.complete_multipart_upload(file_record.s3_key, body.upload_id, parts)
    except Exception:
        logger.exception("멀티파트 완료 실패 file=%s key=%s", file_record.id, file_record.s3_key)
        # 부분 업로드된 파트가 과금되지 않게 best-effort 로 취소.
        try:
            s3.abort_multipart_upload(file_record.s3_key, body.upload_id)
        except Exception:
            logger.warning("멀티파트 취소 실패 file=%s", file_record.id)
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="업로드 완료 처리에 실패했어요. 다시 시도해 주세요.")

    # 기존 confirm 과 동일: 객체 검증 후 추출 큐잉(멱등 — pending/uploading 일 때만).
    if file_record.status in ("pending", "uploading"):
        _verify_uploaded_object(file_record)
        extract_text_task.delay(str(file_id))

    return FileConfirmResponse(file=FileResponse.model_validate(file_record))


# ---------- 유튜브 영상 링크 (S3 업로드 없음) ----------


@router.post("/courses/{course_id}/files/youtube", response_model=FileConfirmResponse, status_code=status.HTTP_201_CREATED)
async def add_youtube_link(
    course_id: uuid.UUID,
    body: YouTubeUploadRequest,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """유튜브 영상 링크를 강의자료로 등록한다.

    파일 업로드와 달리 presigned/S3/confirm 단계가 없다 — File 행을 만들고
    바로 extract_text_task 를 큐잉해 자막을 추출한다. 자막 추출/분류는 워커가 담당.
    """
    from app.services.youtube_extractor import parse_video_id, fetch_video_title

    await owned_course(course_id, current_user, db)

    url = (body.youtube_url or "").strip()
    if not parse_video_id(url):
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="유효한 유튜브 영상 링크가 아니에요. 영상 주소를 다시 확인해 주세요.",
        )

    # 제목은 oembed 로 best-effort 조회 — 실패하면 URL 을 표시명으로.
    # 동기 httpx 호출이라 이벤트 루프를 막지 않도록 스레드로 던진다.
    title = await asyncio.to_thread(fetch_video_title, url)
    filename = title or url

    file_record = File(
        course_id=course_id,
        filename=filename,
        file_type="youtube",
        s3_key=None,
        external_url=url,
        is_syllabus=False,
        status="pending",
    )
    db.add(file_record)
    await db.commit()
    await db.refresh(file_record)

    extract_text_task.delay(str(file_record.id))

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

    if file_record.status in ("pending", "uploading"):
        _verify_uploaded_object(file_record)
        extract_text_task.delay(str(file_id))
    return FileConfirmResponse(file=FileResponse.model_validate(file_record))


# ---------- Auto upload (사용자가 학기/과목/타입 지정 없이 아무거나 업로드) ----------
# 워커가 텍스트 추출 후 syllabus vs material 자동 판정 + (material 이면) 과목 자동 매칭/생성.
# 자세한 분기는 app/tasks/file_tasks.py 의 _auto_dispatch 참고.


@router.post(
    "/files/auto/presigned-url",
    response_model=PresignedUrlResponse,
    status_code=status.HTTP_201_CREATED,
)
async def get_auto_presigned_url(
    body: PresignedUrlRequest,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """학기/과목/타입 지정 없는 업로드용 presigned URL. course_id=None, is_syllabus=False 로
    생성하고 classification_source="auto_pending" 마커를 찍는다.
    워커가 텍스트 보고 분류한 뒤 적절한 후속 파이프라인으로 디스패치한다.
    """
    _validate_upload(body)

    storage_key = s3.build_storage_key(str(current_user.id), body.filename)
    content_type = CONTENT_TYPES.get(body.file_type, "application/octet-stream")

    try:
        upload_url = s3.generate_presigned_put_url(storage_key, content_type)
    except Exception:
        logger.exception("presigned URL 발급 실패 (auto) user=%s", current_user.id)
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
        is_syllabus=False,
        status="pending",
        classification_source="auto_pending",  # 워커가 보고 자동 분기.
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
    "/files/auto/{file_id}/confirm",
    response_model=FileConfirmResponse,
)
async def confirm_auto_upload(
    file_id: uuid.UUID,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """auto 업로드 완료 신호. extract_text_task 트리거 → 워커가 분기."""
    file_record, _ = await owned_file(file_id, current_user, db)
    if file_record.classification_source != "auto_pending":
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="이 엔드포인트는 자동 분류 업로드 전용입니다.",
        )
    if file_record.status in ("pending", "uploading"):
        _verify_uploaded_object(file_record)
        extract_text_task.delay(str(file_id))
    return FileConfirmResponse(file=FileResponse.model_validate(file_record))


class AutoBatchConfirmRequest(BaseModel):
    file_ids: list[uuid.UUID] = Field(..., min_length=1, max_length=30)


@router.post(
    "/files/auto/batch-confirm",
    status_code=status.HTTP_202_ACCEPTED,
)
async def confirm_auto_batch(
    body: AutoBatchConfirmRequest,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """여러 파일을 한 번에 자동 분류 업로드. 강의계획서를 먼저 처리한 뒤 강의자료를 처리한다.

    각 파일은 미리 /files/auto/presigned-url 로 만들어진 auto_pending 파일이어야 한다.
    소유권/상태를 검증하고 S3 업로드 완료를 확인한 뒤, 단일 배치 태스크에 모두 넘긴다.
    """
    valid_ids: list[str] = []
    for fid in body.file_ids:
        file_record, _ = await owned_file(fid, current_user, db)
        if file_record.classification_source != "auto_pending":
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail="배치 업로드는 자동 분류 업로드 전용입니다.",
            )
        if file_record.status in ("pending", "uploading"):
            _verify_uploaded_object(file_record)
            valid_ids.append(str(fid))

    if valid_ids:
        from app.tasks.file_tasks import process_auto_batch_task
        process_auto_batch_task.delay(valid_ids, str(current_user.id))

    return {"queued": valid_ids, "count": len(valid_ids)}


# 진행 중으로 간주할 status 값들. parsing 끝나면 "parsed" 또는 "failed" 로 전환.
_IN_FLIGHT_STATUSES = ("pending", "uploading", "processing", "extracted", "parsing")


@router.get("/files/in-flight-syllabi", response_model=list[FileResponse])
async def list_in_flight_syllabi(
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """현재 사용자에게 속한, 아직 파싱이 끝나지 않은 강의계획서 목록.

    iOS 측에서 업로드 시트를 즉시 닫고 나서도 "지금 분석 중인 게 뭔지" 보여주거나
    완료 시점에 자동 새로고침을 트리거하는 데 사용.

    소유권은 두 경로로 확인:
      - course가 결정된 syllabus: course → semester → user
      - course 미결정 syllabus: uploaded_by_user_id 직접 매칭
    """
    stmt = (
        select(File)
        .outerjoin(Course, File.course_id == Course.id)
        .outerjoin(Semester, Course.semester_id == Semester.id)
        .where(
            File.is_syllabus.is_(True),
            File.status.in_(_IN_FLIGHT_STATUSES),
            or_(
                File.uploaded_by_user_id == current_user.id,
                Semester.user_id == current_user.id,
            ),
        )
        .order_by(File.created_at.desc())
    )
    result = await db.execute(stmt)
    return result.scalars().all()


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
            "file_type": file_row.file_type,
            "s3_key": file_row.s3_key,
            "size_bytes": file_row.size_bytes,
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


class FileRenameRequest(BaseModel):
    filename: str = Field(..., min_length=1, max_length=255)


@router.patch("/files/{file_id}/rename", response_model=FileResponse)
async def rename_file(
    file_id: uuid.UUID,
    body: FileRenameRequest,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """사용자가 파일 표시 이름을 변경한다.

    S3 객체 키(s3_key)는 그대로 두고 DB 의 filename 만 갱신한다 — 다운로드/추출
    파이프라인은 key 기반이라 영향 없음. 확장자 강제는 하지 않는다(표시용 이름).
    """
    file_row, _ = await owned_file(file_id, current_user, db)

    new_name = body.filename.strip()
    if not new_name:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="파일 이름은 비울 수 없어요.",
        )

    file_row.filename = new_name
    await db.commit()
    await db.refresh(file_row)
    return FileResponse.model_validate(file_row)


class FileMoveRequest(BaseModel):
    course_id: uuid.UUID


@router.patch("/files/{file_id}/course", response_model=FileResponse)
async def move_file_to_course(
    file_id: uuid.UUID,
    body: FileMoveRequest,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """자료를 다른 과목으로 이동한다.

    소유한 파일·대상 과목인지 검증 후 course_id 만 바꾼다. 주차/분류는 과목마다 다르므로
    미분류로 초기화(사용자가 새 과목에서 다시 분류·지정). 강의계획서(is_syllabus)는 이동 불가.
    """
    file_row, _ = await owned_file(file_id, current_user, db)
    if file_row.is_syllabus:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="강의계획서는 과목 이동을 지원하지 않아요.",
        )
    # 대상 과목 소유권 검증.
    await owned_course(body.course_id, current_user, db)

    file_row.course_id = body.course_id
    file_row.week = None
    file_row.classification_source = None
    file_row.status = "unclassified"
    file_row.ai_confidence = 0.0
    await db.commit()
    await db.refresh(file_row)
    return FileResponse.model_validate(file_row)


@router.delete("/files/{file_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_file(
    file_id: uuid.UUID,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """사용자가 자신의 파일을 삭제한다.

    S3 객체 + DB row 를 지운다. AI 콘텐츠/노트/플래시카드/튜터 메시지는
    files.id 의 FK CASCADE 로 함께 삭제된다.
    강의계획서면 거기서 생성된 자동 일정/할 일도 정리하고 course 메타를 초기화한다
    (admin_delete_file 과 동일한 정책).
    """
    file_row, _ = await owned_file(file_id, current_user, db)

    # 강의계획서였다면 그 course의 자동 생성 일정/할 일도 함께 비운다.
    if file_row.is_syllabus and file_row.course_id is not None:
        course_id = file_row.course_id
        # FK ondelete=SET NULL 이라 schedule만 지우면 auto todo가 orphan으로 남으니 먼저 todo 제거.
        await db.execute(
            delete(Todo).where(
                Todo.is_auto.is_(True),
                Todo.schedule_id.in_(
                    select(Schedule.id).where(
                        Schedule.course_id == course_id,
                        Schedule.is_auto.is_(True),
                    )
                ),
            )
        )
        await db.execute(
            delete(Schedule).where(
                Schedule.course_id == course_id,
                Schedule.is_auto.is_(True),
            )
        )
        # course 메타도 초기화 (다시 파싱하기 좋게)
        await db.execute(
            update(Course)
            .where(Course.id == course_id)
            .values(weekly_topics=None, weekly_topic_embeddings=None, schedule=None)
        )

    # S3 객체 삭제 — 실패해도 DB row는 지운다(고아 S3 객체는 정리 작업에 맡김).
    # 유튜브 등 s3_key 가 없는 자료는 S3 삭제를 건너뛴다.
    if file_row.s3_key:
        try:
            s3.delete_object(file_row.s3_key)
        except Exception:
            logger.warning("S3 객체 삭제 실패 key=%s", file_row.s3_key, exc_info=True)

    await db.delete(file_row)
    await db.commit()


# ---------- 학습 탭: 다운로드 URL + AI 콘텐츠 ----------


@router.get("/files/{file_id}/presigned-download")
async def get_presigned_download(
    file_id: uuid.UUID,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
) -> dict:
    """학습 탭의 PDF 보기에서 사용할 일회용 GET URL. 기본 1시간 유효."""
    file_row, _ = await owned_file(file_id, current_user, db)
    # 유튜브 등 S3 객체가 없는 리소스는 다운로드 URL 이 없다 — 클라이언트는 external_url 을 쓴다.
    if not file_row.s3_key:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="이 자료는 다운로드할 수 있는 파일이 아니에요.",
        )
    try:
        url = s3.generate_presigned_get_url(file_row.s3_key, expires_in=3600)
    except Exception:
        logger.exception("presigned GET URL 발급 실패 file=%s", file_id)
        raise HTTPException(status_code=503, detail="Failed to generate download URL")
    return {"url": url, "expires_in": 3600, "filename": file_row.filename}


@router.post("/files/{file_id}/ai-contents/{content_type}/regenerate", status_code=status.HTTP_202_ACCEPTED)
async def regenerate_ai_content(
    file_id: uuid.UUID,
    content_type: str,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
) -> dict:
    """사용자가 강제 재생성 — 기존 row 삭제하고 큐에 재요청."""
    from app.models.ai_content import AIContent
    from sqlalchemy import delete
    from app.tasks.file_tasks import generate_summary_task

    if content_type != "summary":
        raise HTTPException(
            status_code=400,
            detail=f"{content_type} 재생성은 /generate force=true 경로를 사용하세요.",
        )

    file_row, _ = await owned_file(file_id, current_user, db)
    await db.execute(
        delete(AIContent).where(
            AIContent.file_id == file_row.id,
            AIContent.content_type == content_type,
        )
    )
    await db.commit()

    generate_summary_task.delay(str(file_id))
    return {"file_id": str(file_id), "content_type": content_type, "status": "queued"}
