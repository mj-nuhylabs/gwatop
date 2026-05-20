"""Day 4: add courses.weekly_topics/embeddings + files.classification_source

Revision ID: d2e3f4a5b6c7
Revises: c1d2e3f4a5b6
Create Date: 2026-05-20 11:00:00.000000

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


revision: str = "d2e3f4a5b6c7"
down_revision: Union[str, Sequence[str], None] = "c1d2e3f4a5b6"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.add_column("courses", sa.Column("weekly_topics", sa.JSON(), nullable=True))
    op.add_column("courses", sa.Column("weekly_topic_embeddings", sa.JSON(), nullable=True))
    op.add_column("files", sa.Column("classification_source", sa.String(), nullable=True))


def downgrade() -> None:
    op.drop_column("files", "classification_source")
    op.drop_column("courses", "weekly_topic_embeddings")
    op.drop_column("courses", "weekly_topics")
