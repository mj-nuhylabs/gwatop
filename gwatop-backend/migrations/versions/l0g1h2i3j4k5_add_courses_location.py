"""add courses.location (강의실)

Revision ID: l0g1h2i3j4k5
Revises: k9f0g1h2i3j4
Create Date: 2026-05-29 00:00:00.000000

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


revision: str = "l0g1h2i3j4k5"
down_revision: Union[str, Sequence[str], None] = "k9f0g1h2i3j4"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.add_column("courses", sa.Column("location", sa.String(), nullable=True))


def downgrade() -> None:
    op.drop_column("courses", "location")
