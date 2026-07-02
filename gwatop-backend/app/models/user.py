from sqlalchemy import String, Boolean, DateTime, Integer
from sqlalchemy.orm import Mapped, mapped_column
from sqlalchemy.dialects.postgresql import UUID
from app.core.database import Base, kst_now_naive
from datetime import datetime
import uuid

class User(Base):
    __tablename__ = "users"

    id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    email: Mapped[str] = mapped_column(String, unique=True, nullable=False)
    hashed_password: Mapped[str | None] = mapped_column(String, nullable=True)
    name: Mapped[str] = mapped_column(String, nullable=False)
    provider: Mapped[str] = mapped_column(String, default="email")  # email | apple | google
    provider_id: Mapped[str | None] = mapped_column(String, nullable=True)
    is_active: Mapped[bool] = mapped_column(Boolean, default=True)
    # 회원가입 시 받는 부가 정보. 모두 nullable — 소셜 로그인은 미수집.
    school: Mapped[str | None] = mapped_column(String, nullable=True)
    student_id: Mapped[str | None] = mapped_column(String, nullable=True)
    referral_code: Mapped[str | None] = mapped_column(String, nullable=True)
    email_verified_at: Mapped[datetime | None] = mapped_column(DateTime, nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime, default=kst_now_naive)
    # --- 구독 (billing) ---
    # plan: free | pro. pro 는 plan_expires_at 이 지나면 free 로 간주(레이지 다운그레이드).
    plan: Mapped[str] = mapped_column(String, default="free", server_default="free", nullable=False)
    plan_interval: Mapped[str | None] = mapped_column(String, nullable=True)  # monthly | yearly
    plan_started_at: Mapped[datetime | None] = mapped_column(DateTime, nullable=True)
    plan_expires_at: Mapped[datetime | None] = mapped_column(DateTime, nullable=True)
    # free 플랜에서 소진한 업로드 횟수 (pro 는 무제한 — 카운트만 하고 제한 안 함).
    upload_used: Mapped[int] = mapped_column(Integer, default=0, server_default="0", nullable=False)
