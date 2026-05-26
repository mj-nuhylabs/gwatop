"""AI 튜터 채팅 메시지.

파일 + 사용자 단위로 멀티턴 채팅 히스토리를 보관. role 은 'user' 또는 'assistant'.
모든 메시지는 영구 저장되어 향후 파인튜닝 데이터로 재활용 가능.
"""

from __future__ import annotations

import uuid
from datetime import datetime

from sqlalchemy import DateTime, ForeignKey, String, Text
from sqlalchemy.dialects.postgresql import UUID
from sqlalchemy.orm import Mapped, mapped_column

from app.core.database import Base, kst_now_naive


class TutorMessage(Base):
    __tablename__ = "tutor_messages"

    id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    user_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("users.id", ondelete="CASCADE"), nullable=False
    )
    file_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("files.id", ondelete="CASCADE"), nullable=False
    )
    role: Mapped[str] = mapped_column(String, nullable=False)  # "user" | "assistant"
    body: Mapped[str] = mapped_column(Text, nullable=False)
    # assistant 메시지에 한해 tokens 사용량을 기록 (파인튜닝 데이터 가공 시 유용).
    tokens: Mapped[int | None] = mapped_column(nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime, default=kst_now_naive, nullable=False)
