"""add file syllabus columns

Revision ID: a3f1c0d20520
Revises: 7dc9d0fec118
Create Date: 2026-05-20 14:00:00.000000

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


revision: str = "a3f1c0d20520"
down_revision: Union[str, Sequence[str], None] = "7dc9d0fec118"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.add_column(
        "files",
        sa.Column("is_syllabus", sa.Boolean(), nullable=False, server_default=sa.false()),
    )
    op.add_column("files", sa.Column("extracted_text", sa.Text(), nullable=True))
    op.add_column("files", sa.Column("parse_error", sa.Text(), nullable=True))
    op.alter_column("files", "is_syllabus", server_default=None)


def downgrade() -> None:
    op.drop_column("files", "parse_error")
    op.drop_column("files", "extracted_text")
    op.drop_column("files", "is_syllabus")
