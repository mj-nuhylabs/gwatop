"""files.class_progress_page — "이번 수업 여기까지" 진도 마크

사용자가 뷰어에서 마크한 페이지(1-based). 다음에 같은 자료를 열면 뷰어가
이 페이지로 자동 스크롤한다. NULL = 마크 없음.

Revision ID: s7n8o9p0q1r2
Revises: r6m7n8o9p0q1
Create Date: 2026-07-02 12:00:00.000000
"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


revision: str = "s7n8o9p0q1r2"
down_revision: Union[str, Sequence[str], None] = "r6m7n8o9p0q1"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.add_column(
        "files",
        sa.Column("class_progress_page", sa.Integer(), nullable=True),
    )


def downgrade() -> None:
    op.drop_column("files", "class_progress_page")
