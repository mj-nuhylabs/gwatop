from sqlalchemy import String, DateTime, ForeignKey, JSON
from sqlalchemy.orm import Mapped, mapped_column, relationship
from sqlalchemy.dialects.postgresql import UUID
from app.core.database import Base
from datetime import datetime
import uuid


class Course(Base):
    __tablename__ = "courses"

    id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    semester_id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), ForeignKey("semesters.id", ondelete="CASCADE"), nullable=False)
    name: Mapped[str] = mapped_column(String, nullable=False)
    professor: Mapped[str | None] = mapped_column(String, nullable=True)
    color: Mapped[str | None] = mapped_column(String(7), nullable=True)
    schedule: Mapped[list | None] = mapped_column(JSON, nullable=True)
    # 강의계획서에서 추출한 주차별 토픽/노트 (Day 4 분류용 컨텍스트).
    # [{"week_number": int, "topic": str|null, "notes": str|null}, ...]
    weekly_topics: Mapped[list | None] = mapped_column(JSON, nullable=True)
    # 위 weekly_topics를 OpenAI 임베딩한 벡터 캐시. classify 시 재계산을 피한다.
    # [{"week_number": int, "vector": [float, ...]}, ...]
    weekly_topic_embeddings: Mapped[list | None] = mapped_column(JSON, nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime, default=datetime.utcnow)

    semester: Mapped["Semester"] = relationship("Semester", back_populates="courses")
    files: Mapped[list["File"]] = relationship("File", back_populates="course", cascade="all, delete-orphan")
    schedules: Mapped[list["Schedule"]] = relationship("Schedule", back_populates="course", cascade="all, delete-orphan")
    todos: Mapped[list["Todo"]] = relationship("Todo", back_populates="course", cascade="all, delete-orphan")
