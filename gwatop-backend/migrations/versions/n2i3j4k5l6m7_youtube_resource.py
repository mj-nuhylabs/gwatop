"""youtube 리소스 지원 — files.external_url 추가 + s3_key nullable

유튜브 링크는 S3 객체가 없는 리소스다(file_type="youtube").
- external_url: 영상 URL 저장 (파일 업로드는 NULL).
- s3_key: 기존엔 NOT NULL 이었으나 유튜브 행은 S3 키가 없으므로 nullable 로 완화.

Revision ID: n2i3j4k5l6m7
Revises: m1h2i3j4k5l6
Create Date: 2026-06-29 00:00:00.000000

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


revision: str = "n2i3j4k5l6m7"
down_revision: Union[str, Sequence[str], None] = "m1h2i3j4k5l6"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.add_column("files", sa.Column("external_url", sa.String(), nullable=True))
    op.alter_column("files", "s3_key", existing_type=sa.String(), nullable=True)


def downgrade() -> None:
    # 다운그레이드 전 유튜브 행이 있으면 s3_key NULL → NOT NULL 복원이 실패하므로
    # 빈 문자열로 메꾼 뒤 제약을 되돌린다.
    op.execute("UPDATE files SET s3_key = '' WHERE s3_key IS NULL")
    op.alter_column("files", "s3_key", existing_type=sa.String(), nullable=False)
    op.drop_column("files", "external_url")
