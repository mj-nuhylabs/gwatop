from sqlalchemy import String, Integer, Float, DateTime, ForeignKey, Boolean, Text
from sqlalchemy.orm import Mapped, mapped_column, relationship
from sqlalchemy.dialects.postgresql import UUID
from app.core.database import Base, kst_now_naive
from datetime import datetime
import uuid


class File(Base):
    __tablename__ = "files"

    id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    # course_id는 강의계획서가 과목 선택 없이 업로드되어 파싱 중인 짧은 구간 동안 NULL.
    # 파싱이 성공하면 course_matcher가 같은 user의 active semester 안에서 매칭/생성한 course로 채운다.
    course_id: Mapped[uuid.UUID | None] = mapped_column(UUID(as_uuid=True), ForeignKey("courses.id", ondelete="CASCADE"), nullable=True)
    # course가 결정되기 전 단계에서 owner를 추적하기 위한 컬럼. 일반 강의 자료는 course→semester→user로 확인하지만
    # 강의계획서가 과목 미선택으로 업로드된 경우 이 컬럼을 통해 소유권을 검증한다.
    uploaded_by_user_id: Mapped[uuid.UUID | None] = mapped_column(
        UUID(as_uuid=True), ForeignKey("users.id", ondelete="CASCADE"), nullable=True
    )
    filename: Mapped[str] = mapped_column(String, nullable=False)
    file_type: Mapped[str] = mapped_column(String, nullable=False, default="other")
    s3_key: Mapped[str] = mapped_column(String, nullable=False)
    size_bytes: Mapped[int | None] = mapped_column(Integer, nullable=True)
    status: Mapped[str] = mapped_column(String, nullable=False, default="uploading")
    week: Mapped[int | None] = mapped_column(Integer, nullable=True)
    ai_confidence: Mapped[float | None] = mapped_column(Float, nullable=True)
    is_syllabus: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False)
    extracted_text: Mapped[str | None] = mapped_column(Text, nullable=True)
    parse_error: Mapped[str | None] = mapped_column(Text, nullable=True)
    page_count: Mapped[int | None] = mapped_column(Integer, nullable=True)
    extract_error: Mapped[str | None] = mapped_column(String, nullable=True)
    # Day 4: 어떤 경로로 주차가 정해졌는지 — "filename" | "embedding" | "manual" | null
    classification_source: Mapped[str | None] = mapped_column(String, nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime, default=kst_now_naive)
    updated_at: Mapped[datetime] = mapped_column(DateTime, default=kst_now_naive, onupdate=kst_now_naive)

    course: Mapped["Course | None"] = relationship("Course", back_populates="files")
    ai_contents: Mapped[list["AIContent"]] = relationship("AIContent", back_populates="file", cascade="all, delete-orphan")
