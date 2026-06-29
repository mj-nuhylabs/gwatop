from sqlalchemy import String, Boolean, DateTime, ForeignKey
from sqlalchemy.orm import Mapped, mapped_column, relationship
from sqlalchemy.dialects.postgresql import UUID
from app.core.database import Base, kst_now_naive
from datetime import datetime
import uuid


class Todo(Base):
    __tablename__ = "todos"

    id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    schedule_id: Mapped[uuid.UUID | None] = mapped_column(UUID(as_uuid=True), ForeignKey("schedules.id", ondelete="SET NULL"), nullable=True)
    course_id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), ForeignKey("courses.id", ondelete="CASCADE"), nullable=False)
    title: Mapped[str] = mapped_column(String, nullable=False)
    # 날짜 미지정 자동 todo(강의계획서/강의자료에 날짜가 안 적힌 시험/과제)를 허용하기 위해 nullable.
    due_date: Mapped[datetime | None] = mapped_column(DateTime, nullable=True)
    priority: Mapped[str] = mapped_column(String, nullable=False, default="low")
    is_done: Mapped[bool] = mapped_column(Boolean, default=False)
    is_auto: Mapped[bool] = mapped_column(Boolean, default=False, nullable=False)
    created_at: Mapped[datetime] = mapped_column(DateTime, default=kst_now_naive)

    schedule: Mapped["Schedule | None"] = relationship("Schedule", back_populates="todos")
    course: Mapped["Course"] = relationship("Course", back_populates="todos")
