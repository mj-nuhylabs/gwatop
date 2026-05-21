"""사용자 디바이스 (APNs 푸시 알림 대상)."""
from datetime import datetime
import uuid

from sqlalchemy import String, DateTime, ForeignKey
from sqlalchemy.dialects.postgresql import UUID
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.core.database import Base, kst_now_naive


class Device(Base):
    __tablename__ = "devices"

    id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    user_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("users.id", ondelete="CASCADE"), nullable=False, index=True
    )
    # APNs는 hex string. 같은 디바이스 = 같은 토큰. unique로 잡아 중복 등록 방지.
    apns_token: Mapped[str] = mapped_column(String, unique=True, nullable=False)
    platform: Mapped[str] = mapped_column(String, default="ios", nullable=False)
    last_seen_at: Mapped[datetime] = mapped_column(DateTime, default=kst_now_naive, nullable=False)
    created_at: Mapped[datetime] = mapped_column(DateTime, default=kst_now_naive, nullable=False)
