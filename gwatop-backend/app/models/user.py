from sqlalchemy import String, Boolean, DateTime
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
