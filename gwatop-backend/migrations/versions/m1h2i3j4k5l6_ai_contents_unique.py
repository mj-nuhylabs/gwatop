"""ai_contents 유니크 제약 (file_id, content_type, scope) — 중복 row 방지

Revision ID: m1h2i3j4k5l6
Revises: l0g1h2i3j4k5
Create Date: 2026-05-29 12:00:00.000000

동시 워커가 같은 (file_id, content_type, scope) 를 중복 INSERT 하면 읽기 측
쿼리(scalar_one_or_none)가 MultipleResultsFound 로 깨졌다. 기존 중복은 가장 최근
(generated_at, id) 1건만 남기고 정리한 뒤 유니크 제약을 건다. 이 복합 인덱스는
file_id 가 선행 컬럼이라 ai_contents.file_id 단일 조회 인덱스 역할도 겸한다.
"""
from typing import Sequence, Union

from alembic import op


revision: str = "m1h2i3j4k5l6"
down_revision: Union[str, Sequence[str], None] = "l0g1h2i3j4k5"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    # 1) 기존 중복 제거 — 그룹당 (generated_at, id) 가 가장 큰 1건만 남긴다.
    #    (generated_at 동률이면 id 로 tiebreak 하여 한 행이 항상 살아남도록 보장.)
    op.execute(
        """
        DELETE FROM ai_contents a
        USING ai_contents b
        WHERE a.file_id = b.file_id
          AND a.content_type = b.content_type
          AND a.scope = b.scope
          AND (a.generated_at < b.generated_at
               OR (a.generated_at = b.generated_at AND a.id < b.id))
        """
    )
    # 2) 유니크 제약 추가 (file_id 선행 → file 기준 조회 인덱스도 겸함).
    op.create_unique_constraint(
        "uq_ai_contents_file_type_scope",
        "ai_contents",
        ["file_id", "content_type", "scope"],
    )


def downgrade() -> None:
    op.drop_constraint("uq_ai_contents_file_type_scope", "ai_contents", type_="unique")
