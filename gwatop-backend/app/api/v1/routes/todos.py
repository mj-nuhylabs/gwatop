import uuid
from datetime import datetime

from fastapi import APIRouter, Depends, Query, status
from sqlalchemy import delete, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.api.v1.dependencies import get_current_user
from app.api.v1.deps_owned import owned_course, owned_todo
from app.core.database import get_db
from app.models.course import Course
from app.models.semester import Semester
from app.models.todo import Todo
from app.models.user import User
from app.schemas.todo import TodoCreate, TodoResponse, TodoUpdate

router = APIRouter(tags=["Todos"])


def _to_response(todo: Todo, course: Course) -> TodoResponse:
    return TodoResponse(
        id=todo.id,
        course_id=todo.course_id,
        schedule_id=todo.schedule_id,
        course_name=course.name,
        course_color=course.color,
        title=todo.title,
        due_date=todo.due_date,
        priority=todo.priority,
        is_done=todo.is_done,
        is_auto=todo.is_auto,
        created_at=todo.created_at,
    )


@router.get("/todos", response_model=list[TodoResponse])
async def list_todos(
    start: datetime | None = Query(None, description="due_date >= start"),
    end: datetime | None = Query(None, description="due_date < end"),
    course_id: uuid.UUID | None = Query(None),
    schedule_id: uuid.UUID | None = Query(None),
    is_done: bool | None = Query(None),
    priority: str | None = Query(None),
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    # tz-aware → naive KST (DB 컬럼이 naive 이므로)
    from app.core.database import to_naive_kst
    start = to_naive_kst(start)
    end = to_naive_kst(end)

    stmt = (
        select(Todo, Course.name, Course.color)
        .join(Course, Todo.course_id == Course.id)
        .join(Semester, Course.semester_id == Semester.id)
        .where(Semester.user_id == current_user.id)
        .order_by(Todo.due_date.asc())
    )
    if start is not None:
        stmt = stmt.where(Todo.due_date >= start)
    if end is not None:
        stmt = stmt.where(Todo.due_date < end)
    if course_id is not None:
        stmt = stmt.where(Todo.course_id == course_id)
    if schedule_id is not None:
        stmt = stmt.where(Todo.schedule_id == schedule_id)
    if is_done is not None:
        stmt = stmt.where(Todo.is_done == is_done)
    if priority is not None:
        stmt = stmt.where(Todo.priority == priority)

    rows = (await db.execute(stmt)).all()
    return [
        TodoResponse(
            id=t.id,
            course_id=t.course_id,
            schedule_id=t.schedule_id,
            course_name=name,
            course_color=color,
            title=t.title,
            due_date=t.due_date,
            priority=t.priority,
            is_done=t.is_done,
            is_auto=t.is_auto,
            created_at=t.created_at,
        )
        for t, name, color in rows
    ]


@router.post("/todos", response_model=TodoResponse, status_code=status.HTTP_201_CREATED)
async def create_todo(
    body: TodoCreate,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    course = await owned_course(body.course_id, current_user, db)

    todo = Todo(
        course_id=body.course_id,
        schedule_id=body.schedule_id,
        title=body.title,
        due_date=body.due_date,
        priority=body.priority,
        is_auto=False,
    )
    db.add(todo)
    await db.commit()
    await db.refresh(todo)
    return _to_response(todo, course)


@router.patch("/todos/{todo_id}", response_model=TodoResponse)
async def update_todo(
    todo_id: uuid.UUID,
    body: TodoUpdate,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    todo, course = await owned_todo(todo_id, current_user, db)

    for field in ("title", "due_date", "priority", "is_done"):
        value = getattr(body, field)
        if value is not None:
            setattr(todo, field, value)

    await db.commit()
    await db.refresh(todo)
    return _to_response(todo, course)


@router.delete("/todos/{todo_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_todo(
    todo_id: uuid.UUID,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    todo, _ = await owned_todo(todo_id, current_user, db)
    await db.delete(todo)
    await db.commit()


async def replace_auto_todos_for_schedule(
    db: AsyncSession,
    schedule,
) -> None:
    """schedule에 연결된 is_auto=True todos를 전부 삭제 후 재생성.

    호출자(schedule create/update)가 commit 책임을 진다.
    """
    from app.services.todo_generator import build_auto_todos  # avoid cycle at import time

    await db.execute(
        delete(Todo).where(
            Todo.schedule_id == schedule.id,
            Todo.is_auto.is_(True),
        )
    )
    for spec in build_auto_todos(schedule):
        db.add(Todo(**spec))
