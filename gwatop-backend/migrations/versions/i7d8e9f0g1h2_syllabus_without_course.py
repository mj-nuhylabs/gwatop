"""Day 7+: allow syllabus upload without preselecting course

- files.course_id 를 nullable로 변경 (강의계획서 파싱 결과로 사후 결정 가능)
- files.uploaded_by_user_id 추가 (course 매칭 전 owner 추적용)

Revision ID: i7d8e9f0g1h2
Revises: h6c7d8e9f0g1
Create Date: 2026-05-21 11:00:00.000000

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


revision: str = "i7d8e9f0g1h2"
down_revision: Union[str, Sequence[str], None] = "h6c7d8e9f0g1"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.alter_column("files", "course_id", existing_type=sa.UUID(), nullable=True)
    op.add_column(
        "files",
        sa.Column("uploaded_by_user_id", sa.UUID(), nullable=True),
    )
    op.create_foreign_key(
        "fk_files_uploaded_by_user_id_users",
        "files", "users",
        ["uploaded_by_user_id"], ["id"],
        ondelete="CASCADE",
    )
    op.create_index("ix_files_uploaded_by_user_id", "files", ["uploaded_by_user_id"])


def downgrade() -> None:
    op.drop_index("ix_files_uploaded_by_user_id", table_name="files")
    op.drop_constraint("fk_files_uploaded_by_user_id_users", "files", type_="foreignkey")
    op.drop_column("files", "uploaded_by_user_id")
    op.alter_column("files", "course_id", existing_type=sa.UUID(), nullable=False)
