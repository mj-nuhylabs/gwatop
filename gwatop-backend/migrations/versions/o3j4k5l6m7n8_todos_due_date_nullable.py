"""todos.due_date nullable (날짜 미지정 자동 todo 허용)

강의계획서/강의자료 파싱 시 정확한 날짜가 없는 시험/과제도 해당 과목 todo로
올리기 위해 due_date 를 nullable 로 변경한다. (schedules.due_date 는 그대로 NOT NULL —
캘린더는 날짜가 필수이므로 날짜 미지정 항목은 todo 로만 등록한다.)

Revision ID: o3j4k5l6m7n8
Revises: n2i3j4k5l6m7
Create Date: 2026-06-29 00:00:00.000000

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


revision: str = "o3j4k5l6m7n8"
down_revision: Union[str, Sequence[str], None] = "n2i3j4k5l6m7"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.alter_column("todos", "due_date", existing_type=sa.DateTime(), nullable=True)


def downgrade() -> None:
    # 날짜 미지정 todo 가 있으면 NOT NULL 복귀가 깨지므로 먼저 제거.
    op.execute("DELETE FROM todos WHERE due_date IS NULL")
    op.alter_column("todos", "due_date", existing_type=sa.DateTime(), nullable=False)
