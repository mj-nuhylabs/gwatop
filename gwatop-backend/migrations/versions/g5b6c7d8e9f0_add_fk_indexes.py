"""Add indexes on frequently-filtered FK columns

Revision ID: g5b6c7d8e9f0
Revises: f4a5b6c7d8e9
Create Date: 2026-05-21 06:00:00.000000

데모 데이터 규모엔 무관하지만, 단순 단일 컬럼 인덱스라서 비용 거의 0.
list_semesters / list_courses / list_files / list_todos 같은
"내 학기·과목·파일·할일" 조회 핫패스를 명시적으로 인덱스로 받침.
"""
from typing import Sequence, Union

from alembic import op


revision: str = "g5b6c7d8e9f0"
down_revision: Union[str, Sequence[str], None] = "f4a5b6c7d8e9"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.create_index("ix_semesters_user_id", "semesters", ["user_id"])
    op.create_index("ix_courses_semester_id", "courses", ["semester_id"])
    op.create_index("ix_files_course_id", "files", ["course_id"])
    op.create_index("ix_todos_course_id", "todos", ["course_id"])


def downgrade() -> None:
    op.drop_index("ix_todos_course_id", table_name="todos")
    op.drop_index("ix_files_course_id", table_name="files")
    op.drop_index("ix_courses_semester_id", table_name="courses")
    op.drop_index("ix_semesters_user_id", table_name="semesters")
