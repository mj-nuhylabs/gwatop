from sqlalchemy import String, DateTime, ForeignKey, JSON
from sqlalchemy.orm import Mapped, mapped_column, relationship
from sqlalchemy.dialects.postgresql import UUID
from app.core.database import Base, kst_now_naive
from datetime import datetime
import uuid


class AIContent(Base):
    __tablename__ = "ai_contents"

    id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    file_id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), ForeignKey("files.id", ondelete="CASCADE"), nullable=False)
    # summary | quiz | flashcard | mindmap | memorize | topics
    content_type: Mapped[str] = mapped_column(String, nullable=False)
    # 페이지 범위 식별자. "all" 또는 "1-3", "5" 등. 같은 file × content_type에 여러 scope 공존 가능.
    scope: Mapped[str] = mapped_column(String, nullable=False, default="all")
    content: Mapped[dict | list | None] = mapped_column(JSON, nullable=True)
    # 어느 사용자가 요청한 결과인지 (파인튜닝 데이터 가공 시 유용).
    requested_by_user_id: Mapped[uuid.UUID | None] = mapped_column(
        UUID(as_uuid=True), ForeignKey("users.id", ondelete="SET NULL"), nullable=True
    )
    generated_at: Mapped[datetime] = mapped_column(DateTime, default=kst_now_naive)

    file: Mapped["File"] = relationship("File", back_populates="ai_contents")
