"""구독(billing) — users 테이블에 플랜/업로드 사용량 컬럼 추가

free 플랜은 업로드 횟수 제한(FREE_UPLOAD_LIMIT), pro 는 무제한.
pro 는 plan_expires_at 경과 시 free 로 레이지 다운그레이드한다.

Revision ID: s7n8o9p1q2r3
Revises: r6m7n8o9p0q1
Create Date: 2026-07-02 12:00:00.000000
"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


revision: str = "s7n8o9p1q2r3"
down_revision: Union[str, Sequence[str], None] = "r6m7n8o9p0q1"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.add_column("users", sa.Column("plan", sa.String(), nullable=False, server_default="free"))
    op.add_column("users", sa.Column("plan_interval", sa.String(), nullable=True))
    op.add_column("users", sa.Column("plan_started_at", sa.DateTime(), nullable=True))
    op.add_column("users", sa.Column("plan_expires_at", sa.DateTime(), nullable=True))
    op.add_column("users", sa.Column("upload_used", sa.Integer(), nullable=False, server_default="0"))


def downgrade() -> None:
    op.drop_column("users", "upload_used")
    op.drop_column("users", "plan_expires_at")
    op.drop_column("users", "plan_started_at")
    op.drop_column("users", "plan_interval")
    op.drop_column("users", "plan")
