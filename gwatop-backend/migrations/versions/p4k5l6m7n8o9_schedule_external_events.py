"""schedules 외부(Apple 캘린더) 이벤트 지원

Apple 캘린더에서 가져온 개인 일정을 schedules 에 저장해 웹/위젯에서도 보이게 한다.
이 이벤트들은 과목(course)에 속하지 않으므로:
- course_id 를 nullable 로 바꾸고(과목 일정은 그대로 course_id 보유),
- 소유권을 위해 user_id(nullable FK) 를 추가한다(과목 일정은 course→semester→user 로 소유, 외부 일정은 user_id 로 소유),
- source("apple_calendar" 등)와 external_id(Apple 이벤트 식별자, upsert/삭제 동기화용)를 추가한다.

Revision ID: p4k5l6m7n8o9
Revises: o3j4k5l6m7n8
Create Date: 2026-06-30 00:00:00.000000
"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa
from sqlalchemy.dialects import postgresql


revision: str = "p4k5l6m7n8o9"
down_revision: Union[str, Sequence[str], None] = "o3j4k5l6m7n8"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.add_column("schedules", sa.Column("user_id", postgresql.UUID(as_uuid=True), nullable=True))
    op.add_column("schedules", sa.Column("source", sa.String(), nullable=True))
    op.add_column("schedules", sa.Column("external_id", sa.String(), nullable=True))
    op.create_foreign_key(
        "fk_schedules_user_id", "schedules", "users", ["user_id"], ["id"], ondelete="CASCADE"
    )
    op.alter_column(
        "schedules", "course_id", existing_type=postgresql.UUID(as_uuid=True), nullable=True
    )
    # 외부 일정 upsert/조회용 인덱스 (user_id, external_id).
    op.create_index(
        "ix_schedules_user_external", "schedules", ["user_id", "external_id"]
    )


def downgrade() -> None:
    op.drop_index("ix_schedules_user_external", table_name="schedules")
    # 외부 일정(course_id NULL) 은 NOT NULL 복귀 전에 제거.
    op.execute("DELETE FROM schedules WHERE course_id IS NULL")
    op.alter_column(
        "schedules", "course_id", existing_type=postgresql.UUID(as_uuid=True), nullable=False
    )
    op.drop_constraint("fk_schedules_user_id", "schedules", type_="foreignkey")
    op.drop_column("schedules", "external_id")
    op.drop_column("schedules", "source")
    op.drop_column("schedules", "user_id")
