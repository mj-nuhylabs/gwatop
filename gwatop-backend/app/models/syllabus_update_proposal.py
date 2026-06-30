"""학습자료에서 발견한 강의계획서 갱신 후보 (Stage 3 변경 탐지).

강의계획서에 저장된 강의시간/강의실/과제마감과, 새로 올라온 학습자료 본문에
적힌 '변경/연기/공지' 정보가 어긋날 때 만들어지는 **제안**이다.
절대 자동 반영하지 않는다 — status='pending' 으로 쌓아두고, 사용자가 승인한
항목만 approve 시점에 실제 DB(Course/Schedule)에 반영한다.
"""

from sqlalchemy import String, Float, DateTime, ForeignKey, Text
from sqlalchemy.orm import Mapped, mapped_column, relationship
from sqlalchemy.dialects.postgresql import UUID
from app.core.database import Base, kst_now_naive
from datetime import datetime
import uuid


class SyllabusUpdateProposal(Base):
    __tablename__ = "syllabus_update_proposals"

    id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    course_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("courses.id", ondelete="CASCADE"), nullable=False
    )
    # 이 제안을 촉발한 학습자료. 파일이 지워져도 제안은 남도록 SET NULL.
    file_id: Mapped[uuid.UUID | None] = mapped_column(
        UUID(as_uuid=True), ForeignKey("files.id", ondelete="SET NULL"), nullable=True
    )
    # 과제마감 변경일 때 대상 일정(과제/시험) — approve 시 이 schedule.due_date 를 갱신.
    schedule_id: Mapped[uuid.UUID | None] = mapped_column(
        UUID(as_uuid=True), ForeignKey("schedules.id", ondelete="SET NULL"), nullable=True
    )

    # "class_time" | "classroom" | "assignment_due"
    field: Mapped[str] = mapped_column(String, nullable=False)
    # 과제마감 제안에서 대상 일정 제목(매칭/표시용). 그 외엔 null.
    target_title: Mapped[str | None] = mapped_column(String, nullable=True)
    old_value: Mapped[str | None] = mapped_column(Text, nullable=True)
    new_value: Mapped[str] = mapped_column(Text, nullable=False)
    evidence: Mapped[str] = mapped_column(Text, nullable=False)
    confidence: Mapped[float] = mapped_column(Float, nullable=False, default=0.0)

    # "pending" | "approved" | "rejected"
    status: Mapped[str] = mapped_column(String, nullable=False, default="pending")

    created_at: Mapped[datetime] = mapped_column(DateTime, default=kst_now_naive)
    updated_at: Mapped[datetime] = mapped_column(
        DateTime, default=kst_now_naive, onupdate=kst_now_naive
    )

    course: Mapped["Course"] = relationship("Course")
