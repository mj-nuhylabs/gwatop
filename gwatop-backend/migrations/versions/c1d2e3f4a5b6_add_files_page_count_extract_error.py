"""add files.page_count, files.extract_error

원래 hyunnow의 8a1c3e9f2b10 마이그레이션 중 `extracted_text`는 mj의 a3f1c0d20520
에서 이미 추가되어 EC2 DB에 적용됨. 두 브랜치를 머지하면서 중복을 피하기 위해
hyunnow의 마이그레이션은 삭제하고, hyunnow가 새로 도입한 page_count/extract_error
만 별도 리비전으로 분리한다.

Revision ID: c1d2e3f4a5b6
Revises: a3f1c0d20520
Create Date: 2026-05-20 10:00:00.000000

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


revision: str = "c1d2e3f4a5b6"
down_revision: Union[str, Sequence[str], None] = "a3f1c0d20520"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.add_column("files", sa.Column("page_count", sa.Integer(), nullable=True))
    op.add_column("files", sa.Column("extract_error", sa.String(), nullable=True))


def downgrade() -> None:
    op.drop_column("files", "extract_error")
    op.drop_column("files", "page_count")
