"""Day 6: add indexes on schedules.due_date for calendar range queries

Revision ID: e3f4a5b6c7d8
Revises: d2e3f4a5b6c7
Create Date: 2026-05-21 09:30:00.000000

"""
from typing import Sequence, Union

from alembic import op


revision: str = "e3f4a5b6c7d8"
down_revision: Union[str, Sequence[str], None] = "d2e3f4a5b6c7"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.create_index(
        "ix_schedules_due_date",
        "schedules",
        ["due_date"],
    )
    op.create_index(
        "ix_schedules_course_id_due_date",
        "schedules",
        ["course_id", "due_date"],
    )


def downgrade() -> None:
    op.drop_index("ix_schedules_course_id_due_date", table_name="schedules")
    op.drop_index("ix_schedules_due_date", table_name="schedules")
