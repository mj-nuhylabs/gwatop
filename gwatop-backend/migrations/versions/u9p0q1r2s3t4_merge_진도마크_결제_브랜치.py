"""merge 진도마크 + 결제 브랜치

Revision ID: u9p0q1r2s3t4
Revises: s7n8o9p0q1r2, t8o9p1q2r3s4
Create Date: 2026-07-02 14:07:06.155878

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


# revision identifiers, used by Alembic.
revision: str = 'u9p0q1r2s3t4'
down_revision: Union[str, Sequence[str], None] = ('s7n8o9p0q1r2', 't8o9p1q2r3s4')
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    """Upgrade schema."""
    pass


def downgrade() -> None:
    """Downgrade schema."""
    pass
