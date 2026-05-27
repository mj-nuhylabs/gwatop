"""사용자별 플래시카드 학습 상태 (알아요 / 몰라요).

같은 ai_contents 의 flashcard 결과를 여러 사용자가 학습할 때, 각자의 진척도를
독립적으로 저장한다. 카드 식별자는 front 텍스트 — 백엔드는 카드 본문 변경을 추적하지
않고 사용자 마킹만 보관하면 된다 (재생성으로 카드가 바뀌면 자연스럽게 매핑이 끊김).
"""

from __future__ import annotations

import uuid
from datetime import datetime

from sqlalchemy import DateTime, ForeignKey, String, UniqueConstraint, Index
from sqlalchemy.dialects.postgresql import UUID
from sqlalchemy.orm import Mapped, mapped_column

from app.core.database import Base, kst_now_naive


class UserFlashcardStatus(Base):
    __tablename__ = "user_flashcard_status"
    __table_args__ = (
        UniqueConstraint(
            "user_id", "file_id", "scope", "card_front",
            name="uq_user_flashcard_status_per_card",
        ),
        Index(
            "ix_user_flashcard_status_lookup",
            "user_id", "file_id", "scope",
        ),
    )

    id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    user_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("users.id", ondelete="CASCADE"), nullable=False
    )
    file_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("files.id", ondelete="CASCADE"), nullable=False
    )
    # ai_contents 와 동일한 페이지 범위 식별자 ("all" / "1-3" 등).
    scope: Mapped[str] = mapped_column(String, nullable=False, default="all")
    # 카드의 front 텍스트. GwaTopAIFlashcard.id 가 front 라 그대로 식별자로 쓴다.
    card_front: Mapped[str] = mapped_column(String, nullable=False)
    # "known" | "unknown". row 존재가 곧 "마킹 됨"을 의미하고, 미마킹은 row 없음.
    status: Mapped[str] = mapped_column(String, nullable=False)
    updated_at: Mapped[datetime] = mapped_column(
        DateTime, default=kst_now_naive, onupdate=kst_now_naive, nullable=False
    )
