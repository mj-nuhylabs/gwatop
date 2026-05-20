"""add files.extracted_text, page_count, extract_error

Revision ID: 8a1c3e9f2b10
Revises: 7dc9d0fec118
Create Date: 2026-05-20 00:00:00.000000

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


revision: str = "8a1c3e9f2b10"
down_revision: Union[str, Sequence[str], None] = "7dc9d0fec118"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.add_column("files", sa.Column("extracted_text", sa.Text(), nullable=True))
    op.add_column("files", sa.Column("page_count", sa.Integer(), nullable=True))
    op.add_column("files", sa.Column("extract_error", sa.String(), nullable=True))


def downgrade() -> None:
    op.drop_column("files", "extract_error")
    op.drop_column("files", "page_count")
    op.drop_column("files", "extracted_text")
