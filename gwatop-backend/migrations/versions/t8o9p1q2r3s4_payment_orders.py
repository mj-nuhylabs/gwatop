"""PG 결제 주문 — payment_orders 테이블

토스페이먼츠/카카오페이 결제 흐름의 주문 원장. checkout 에서 pending 으로 생성,
PG 승인 콜백에서 paid 로 전환하며 Pro 를 활성화한다.

Revision ID: t8o9p1q2r3s4
Revises: s7n8o9p1q2r3
Create Date: 2026-07-02 13:00:00.000000
"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


revision: str = "t8o9p1q2r3s4"
down_revision: Union[str, Sequence[str], None] = "s7n8o9p1q2r3"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.create_table(
        "payment_orders",
        sa.Column("id", sa.UUID(), nullable=False),
        sa.Column("user_id", sa.UUID(), nullable=False),
        sa.Column("provider", sa.String(), nullable=False),
        sa.Column("interval", sa.String(), nullable=False),
        sa.Column("amount", sa.Integer(), nullable=False),
        sa.Column("order_name", sa.String(), nullable=False),
        sa.Column("status", sa.String(), nullable=False, server_default="pending"),
        sa.Column("payment_key", sa.String(), nullable=True),
        sa.Column("created_at", sa.DateTime(), nullable=False),
        sa.Column("updated_at", sa.DateTime(), nullable=False),
        sa.ForeignKeyConstraint(["user_id"], ["users.id"], ondelete="CASCADE"),
        sa.PrimaryKeyConstraint("id"),
    )
    # 사용자별 주문 조회 + pending 주문 승인 매칭 패턴.
    op.create_index("ix_payment_orders_user_status", "payment_orders", ["user_id", "status"])


def downgrade() -> None:
    op.drop_index("ix_payment_orders_user_status", table_name="payment_orders")
    op.drop_table("payment_orders")
