from sqlalchemy import String, Boolean, DateTime, ForeignKey, Text
from sqlalchemy.orm import Mapped, mapped_column, relationship
from sqlalchemy.dialects.postgresql import UUID
from app.core.database import Base, kst_now_naive
from datetime import datetime
import uuid


class Schedule(Base):
    __tablename__ = "schedules"

    id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    # 과목 일정은 course_id 보유(소유권 course→semester→user). 외부(Apple 캘린더) 일정은
    # course 가 없어 course_id=NULL + user_id 로 소유권을 가진다.
    course_id: Mapped[uuid.UUID | None] = mapped_column(
        UUID(as_uuid=True), ForeignKey("courses.id", ondelete="CASCADE"), nullable=True
    )
    user_id: Mapped[uuid.UUID | None] = mapped_column(
        UUID(as_uuid=True), ForeignKey("users.id", ondelete="CASCADE"), nullable=True
    )
    title: Mapped[str] = mapped_column(String, nullable=False)
    type: Mapped[str] = mapped_column(String, nullable=False)
    due_date: Mapped[datetime] = mapped_column(DateTime, nullable=False)
    # 종료 시각 — 주로 외부(Apple 캘린더) 일정의 end. 과목 일정/시간 미지정이면 NULL.
    end_date: Mapped[datetime | None] = mapped_column(DateTime, nullable=True)
    description: Mapped[str | None] = mapped_column(Text, nullable=True)
    is_auto: Mapped[bool] = mapped_column(Boolean, default=False)
    # 출처: None/"manual"/"ai_parsed"(과목 일정) 또는 "apple_calendar"(외부 동기화).
    source: Mapped[str | None] = mapped_column(String, nullable=True)
    # 외부 일정 동기화용 안정 식별자(Apple EKEvent identifier). upsert/삭제 매칭에 사용.
    external_id: Mapped[str | None] = mapped_column(String, nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime, default=kst_now_naive)

    course: Mapped["Course"] = relationship("Course", back_populates="schedules")
    todos: Mapped[list["Todo"]] = relationship("Todo", back_populates="schedule")
