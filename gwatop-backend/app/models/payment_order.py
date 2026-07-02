from sqlalchemy import String, Integer, DateTime, ForeignKey
from sqlalchemy.orm import Mapped, mapped_column
from sqlalchemy.dialects.postgresql import UUID
from app.core.database import Base, kst_now_naive
from datetime import datetime
import uuid


class PaymentOrder(Base):
    """PG 결제 주문. checkout 에서 pending 으로 생성 → PG 승인 시 paid + Pro 활성화.

    provider="dev" 는 PG 미설정 상태의 즉시 활성화 주문(감사 로그 용도로만 남긴다).
    """

    __tablename__ = "payment_orders"

    id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    user_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("users.id", ondelete="CASCADE"), nullable=False
    )
    provider: Mapped[str] = mapped_column(String, nullable=False)  # toss | kakaopay | dev
    interval: Mapped[str] = mapped_column(String, nullable=False)  # monthly | yearly
    amount: Mapped[int] = mapped_column(Integer, nullable=False)  # KRW
    order_name: Mapped[str] = mapped_column(String, nullable=False)
    status: Mapped[str] = mapped_column(String, default="pending", nullable=False)  # pending | paid | failed | cancelled
    # PG 측 결제 식별자 — toss: paymentKey, kakaopay: tid.
    payment_key: Mapped[str | None] = mapped_column(String, nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime, default=kst_now_naive)
    updated_at: Mapped[datetime] = mapped_column(DateTime, default=kst_now_naive, onupdate=kst_now_naive)
