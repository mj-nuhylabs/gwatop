from pydantic import BaseModel
from datetime import datetime
from uuid import UUID
from typing import Literal


FILE_TYPES = Literal["pdf", "pptx", "docx", "image", "other"]


class PresignedUrlRequest(BaseModel):
    filename: str
    file_type: FILE_TYPES
    file_size_bytes: int


class PresignedUrlResponse(BaseModel):
    upload_url: str
    storage_key: str
    file_id: UUID


class FileResponse(BaseModel):
    id: UUID
    course_id: UUID
    filename: str
    file_type: str
    s3_key: str
    size_bytes: int | None
    status: str
    week: int | None
    ai_confidence: float | None
    created_at: datetime
    updated_at: datetime

    model_config = {"from_attributes": True}


class FileConfirmResponse(BaseModel):
    file: FileResponse
