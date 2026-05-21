"""Day 6: add todos.is_auto + indexes for todos.due_date / schedule_id

Revision ID: f4a5b6c7d8e9
Revises: e3f4a5b6c7d8
Create Date: 2026-05-21 13:30:00.000000

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


revision: str = "f4a5b6c7d8e9"
down_revision: Union[str, Sequence[str], None] = "e3f4a5b6c7d8"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.add_column(
        "todos",
        sa.Column("is_auto", sa.Boolean(), nullable=False, server_default=sa.false()),
    )
    op.alter_column("todos", "is_auto", server_default=None)
    op.create_index("ix_todos_due_date", "todos", ["due_date"])
    op.create_index("ix_todos_schedule_id", "todos", ["schedule_id"])


def downgrade() -> None:
    op.drop_index("ix_todos_schedule_id", table_name="todos")
    op.drop_index("ix_todos_due_date", table_name="todos")
    op.drop_column("todos", "is_auto")
