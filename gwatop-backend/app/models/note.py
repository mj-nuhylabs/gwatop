"""사용자가 파일별로 직접 적은 메모/노트.

학습 탭의 '노트' 기능. AI가 생성한 ai_contents 와 달리 user 가 직접 입력하며,
훗날 AI 튜터의 컨텍스트에 함께 합칠 수 있다.
"""

from __future__ import annotations

import uuid
from datetime import datetime

from sqlalchemy import DateTime, ForeignKey, String, Text
from sqlalchemy.dialects.postgresql import UUID
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.core.database import Base, kst_now_naive


class UserNote(Base):
    __tablename__ = "user_notes"

    id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    user_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("users.id", ondelete="CASCADE"), nullable=False
    )
    file_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("files.id", ondelete="CASCADE"), nullable=False
    )
    title: Mapped[str | None] = mapped_column(String, nullable=True)
    body: Mapped[str] = mapped_column(Text, nullable=False, default="")
    created_at: Mapped[datetime] = mapped_column(DateTime, default=kst_now_naive, nullable=False)
    updated_at: Mapped[datetime] = mapped_column(
        DateTime, default=kst_now_naive, onupdate=kst_now_naive, nullable=False
    )
