"""schedules.end_date 추가 (외부 Apple 캘린더 일정의 종료 시각 저장)

Apple 캘린더 동기화 시 이벤트의 end 시각을 함께 보관한다. 과목 일정/시간 미지정
일정은 NULL. 표시(웹/위젯/iOS)에서 start–end 범위로 활용한다.

Revision ID: q5l6m7n8o9p0
Revises: p4k5l6m7n8o9
Create Date: 2026-06-30 00:00:00.000000
"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


revision: str = "q5l6m7n8o9p0"
down_revision: Union[str, Sequence[str], None] = "p4k5l6m7n8o9"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.add_column("schedules", sa.Column("end_date", sa.DateTime(), nullable=True))


def downgrade() -> None:
    op.drop_column("schedules", "end_date")
