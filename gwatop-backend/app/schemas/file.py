from pydantic import BaseModel
from datetime import datetime
from uuid import UUID
from typing import Literal


FILE_TYPES = Literal["pdf", "pptx", "docx", "image", "other", "youtube"]


class PresignedUrlRequest(BaseModel):
    filename: str
    file_type: FILE_TYPES
    file_size_bytes: int
    is_syllabus: bool = False


class YouTubeUploadRequest(BaseModel):
    """유튜브 영상 링크 등록 — S3 업로드 없이 자막을 추출해 학습 자료로 만든다."""
    youtube_url: str


class PresignedUrlResponse(BaseModel):
    upload_url: str
    storage_key: str
    file_id: UUID


class FileResponse(BaseModel):
    id: UUID
    # 강의계획서가 과목 미선택으로 업로드된 직후엔 course_id가 NULL이고
    # 파싱이 끝나면 course_matcher가 채운다.
    course_id: UUID | None
    filename: str
    file_type: str
    s3_key: str | None = None
    size_bytes: int | None
    status: str
    week: int | None
    ai_confidence: float | None
    is_syllabus: bool
    external_url: str | None = None
    classification_source: str | None = None
    parse_error: str | None
    created_at: datetime
    updated_at: datetime

    model_config = {"from_attributes": True}


class FileConfirmResponse(BaseModel):
    file: FileResponse
