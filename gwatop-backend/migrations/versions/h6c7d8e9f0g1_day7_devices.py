"""Day 7: add devices table for APNs push targets

Revision ID: h6c7d8e9f0g1
Revises: g5b6c7d8e9f0
Create Date: 2026-05-21 09:00:00.000000

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


revision: str = "h6c7d8e9f0g1"
down_revision: Union[str, Sequence[str], None] = "g5b6c7d8e9f0"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.create_table(
        "devices",
        sa.Column("id", sa.UUID(), nullable=False),
        sa.Column("user_id", sa.UUID(), nullable=False),
        sa.Column("apns_token", sa.String(), nullable=False),
        sa.Column("platform", sa.String(), nullable=False, server_default="ios"),
        sa.Column("last_seen_at", sa.DateTime(), nullable=False),
        sa.Column("created_at", sa.DateTime(), nullable=False),
        sa.ForeignKeyConstraint(["user_id"], ["users.id"], ondelete="CASCADE"),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint("apns_token"),
    )
    op.create_index("ix_devices_user_id", "devices", ["user_id"])


def downgrade() -> None:
    op.drop_index("ix_devices_user_id", table_name="devices")
    op.drop_table("devices")
