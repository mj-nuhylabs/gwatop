"""study tabs: ai_contents scope + user_notes + tutor_messages

Revision ID: j8e9f0g1h2i3
Revises: i7d8e9f0g1h2
Create Date: 2026-05-26 00:00:00.000000

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


revision: str = "j8e9f0g1h2i3"
down_revision: Union[str, Sequence[str], None] = "i7d8e9f0g1h2"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    # ai_contents 확장: 같은 파일에 페이지 범위별 다른 결과 공존 가능
    op.add_column(
        "ai_contents",
        sa.Column("scope", sa.String(), server_default="all", nullable=False),
    )
    op.add_column(
        "ai_contents",
        sa.Column("requested_by_user_id", sa.UUID(), nullable=True),
    )
    op.create_foreign_key(
        "fk_ai_contents_requested_by_user",
        "ai_contents", "users",
        ["requested_by_user_id"], ["id"],
        ondelete="SET NULL",
    )

    # user_notes: 사용자가 직접 적은 메모
    op.create_table(
        "user_notes",
        sa.Column("id", sa.UUID(), primary_key=True),
        sa.Column("user_id", sa.UUID(), nullable=False),
        sa.Column("file_id", sa.UUID(), nullable=False),
        sa.Column("title", sa.String(), nullable=True),
        sa.Column("body", sa.Text(), nullable=False, server_default=""),
        sa.Column("created_at", sa.DateTime(), nullable=False),
        sa.Column("updated_at", sa.DateTime(), nullable=False),
        sa.ForeignKeyConstraint(["user_id"], ["users.id"], ondelete="CASCADE"),
        sa.ForeignKeyConstraint(["file_id"], ["files.id"], ondelete="CASCADE"),
    )
    op.create_index("ix_user_notes_file_user", "user_notes", ["file_id", "user_id"])

    # tutor_messages: AI 튜터 채팅 영구 저장
    op.create_table(
        "tutor_messages",
        sa.Column("id", sa.UUID(), primary_key=True),
        sa.Column("user_id", sa.UUID(), nullable=False),
        sa.Column("file_id", sa.UUID(), nullable=False),
        sa.Column("role", sa.String(), nullable=False),
        sa.Column("body", sa.Text(), nullable=False),
        sa.Column("tokens", sa.Integer(), nullable=True),
        sa.Column("created_at", sa.DateTime(), nullable=False),
        sa.ForeignKeyConstraint(["user_id"], ["users.id"], ondelete="CASCADE"),
        sa.ForeignKeyConstraint(["file_id"], ["files.id"], ondelete="CASCADE"),
    )
    op.create_index(
        "ix_tutor_messages_file_user_created",
        "tutor_messages", ["file_id", "user_id", "created_at"],
    )


def downgrade() -> None:
    op.drop_index("ix_tutor_messages_file_user_created", table_name="tutor_messages")
    op.drop_table("tutor_messages")
    op.drop_index("ix_user_notes_file_user", table_name="user_notes")
    op.drop_table("user_notes")
    op.drop_constraint("fk_ai_contents_requested_by_user", "ai_contents", type_="foreignkey")
    op.drop_column("ai_contents", "requested_by_user_id")
    op.drop_column("ai_contents", "scope")
