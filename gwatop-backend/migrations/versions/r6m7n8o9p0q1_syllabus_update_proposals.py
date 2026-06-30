"""Stage 3: 변경 탐지 — syllabus_update_proposals 테이블

학습자료에서 발견한 강의계획서 갱신 후보를 쌓아두는 테이블. 자동 반영 금지,
사용자 승인(approve) 시에만 Course/Schedule 에 실제 반영한다.

Revision ID: r6m7n8o9p0q1
Revises: q5l6m7n8o9p0
Create Date: 2026-06-30 12:00:00.000000
"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


revision: str = "r6m7n8o9p0q1"
down_revision: Union[str, Sequence[str], None] = "q5l6m7n8o9p0"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.create_table(
        "syllabus_update_proposals",
        sa.Column("id", sa.UUID(), nullable=False),
        sa.Column("course_id", sa.UUID(), nullable=False),
        sa.Column("file_id", sa.UUID(), nullable=True),
        sa.Column("schedule_id", sa.UUID(), nullable=True),
        sa.Column("field", sa.String(), nullable=False),
        sa.Column("target_title", sa.String(), nullable=True),
        sa.Column("old_value", sa.Text(), nullable=True),
        sa.Column("new_value", sa.Text(), nullable=False),
        sa.Column("evidence", sa.Text(), nullable=False),
        sa.Column("confidence", sa.Float(), nullable=False, server_default="0"),
        sa.Column("status", sa.String(), nullable=False, server_default="pending"),
        # 다른 테이블과 동일 — ORM 의 kst_now_naive 파이썬 기본값으로 항상 채워진다.
        sa.Column("created_at", sa.DateTime(), nullable=False),
        sa.Column("updated_at", sa.DateTime(), nullable=False),
        sa.ForeignKeyConstraint(["course_id"], ["courses.id"], ondelete="CASCADE"),
        sa.ForeignKeyConstraint(["file_id"], ["files.id"], ondelete="SET NULL"),
        sa.ForeignKeyConstraint(["schedule_id"], ["schedules.id"], ondelete="SET NULL"),
        sa.PrimaryKeyConstraint("id"),
    )
    # 과목별 pending 제안 조회 + 사용자 인박스 조회 패턴을 위한 인덱스.
    op.create_index(
        "ix_syllabus_update_proposals_course_status",
        "syllabus_update_proposals",
        ["course_id", "status"],
    )


def downgrade() -> None:
    op.drop_index(
        "ix_syllabus_update_proposals_course_status",
        table_name="syllabus_update_proposals",
    )
    op.drop_table("syllabus_update_proposals")
