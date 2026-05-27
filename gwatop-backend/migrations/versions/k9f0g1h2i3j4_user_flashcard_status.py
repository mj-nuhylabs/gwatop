"""user_flashcard_status: 사용자별 카드 알아요/몰라요 마킹 저장

Revision ID: k9f0g1h2i3j4
Revises: j8e9f0g1h2i3
Create Date: 2026-05-27 00:00:00.000000

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


revision: str = "k9f0g1h2i3j4"
down_revision: Union[str, Sequence[str], None] = "j8e9f0g1h2i3"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.create_table(
        "user_flashcard_status",
        sa.Column("id", sa.UUID(), primary_key=True),
        sa.Column("user_id", sa.UUID(), nullable=False),
        sa.Column("file_id", sa.UUID(), nullable=False),
        sa.Column("scope", sa.String(), nullable=False, server_default="all"),
        sa.Column("card_front", sa.String(), nullable=False),
        sa.Column("status", sa.String(), nullable=False),
        sa.Column("updated_at", sa.DateTime(), nullable=False),
        sa.ForeignKeyConstraint(["user_id"], ["users.id"], ondelete="CASCADE"),
        sa.ForeignKeyConstraint(["file_id"], ["files.id"], ondelete="CASCADE"),
        sa.UniqueConstraint(
            "user_id", "file_id", "scope", "card_front",
            name="uq_user_flashcard_status_per_card",
        ),
    )
    op.create_index(
        "ix_user_flashcard_status_lookup",
        "user_flashcard_status",
        ["user_id", "file_id", "scope"],
    )


def downgrade() -> None:
    op.drop_index(
        "ix_user_flashcard_status_lookup", table_name="user_flashcard_status"
    )
    op.drop_table("user_flashcard_status")
