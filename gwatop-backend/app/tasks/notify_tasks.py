"""푸시 알림 Celery 태스크.

- `tasks.notify_due_dday` (Beat schedule): 매일 09:00 KST. 다음 24시간 안 마감되는
  todos/schedules가 있는 유저들에게 push.
- `tasks.notify_classified` (기존 file_tasks의 placeholder를 대체): 파일 분류 완료 시
  소유 유저에게 push. file_tasks.py에서 호출.

설계:
- 모든 Celery 태스크는 `asyncio.run(...)` + NullPool 패턴 (file_tasks.py와 동일 — Celery
  prefork 워커에서 async SQLAlchemy를 안전하게 쓰기 위함).
"""
from __future__ import annotations

import asyncio
import logging
from datetime import timedelta
from uuid import UUID

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.database import kst_now_naive, make_celery_session_factory
from app.models.course import Course
from app.models.file import File
from app.models.schedule import Schedule
from app.models.semester import Semester
from app.models.todo import Todo
from app.services.apns import push_to_user
from app.tasks.celery_app import celery_app

logger = logging.getLogger(__name__)


def _run_with_fresh_engine(coro_factory):
    """Celery 태스크에서 async 코드 실행 — file_tasks.py와 동일 패턴."""
    async def runner():
        engine, SessionLocal = make_celery_session_factory()
        try:
            await coro_factory(SessionLocal)
        finally:
            await engine.dispose()
    asyncio.run(runner())


# ---------- Daily D-Day notifier ----------

@celery_app.task(name="tasks.notify_due_dday")
def notify_due_dday_task() -> None:
    """매일 09:00 KST. 다음 24시간 안 마감되는 todo/exam/assignment를 가진 유저 each에게 1건 푸시."""
    _run_with_fresh_engine(_run_notify_due_dday)


async def _run_notify_due_dday(SessionLocal) -> None:
    async with SessionLocal() as session:
        now = kst_now_naive()
        horizon = now + timedelta(hours=24)

        # 다음 24h 안 todos가 있는 유저들
        users_with_todos = (
            await session.execute(
                select(Semester.user_id, Todo.id, Todo.title)
                .join(Course, Semester.id == Course.semester_id)
                .join(Todo, Todo.course_id == Course.id)
                .where(
                    Todo.is_done.is_(False),
                    Todo.due_date >= now,
                    Todo.due_date < horizon,
                )
            )
        ).all()

        # 다음 24h 안 schedules (시험/과제) 가 있는 유저들
        users_with_schedules = (
            await session.execute(
                select(Semester.user_id, Schedule.id, Schedule.title, Schedule.type)
                .join(Course, Semester.id == Course.semester_id)
                .join(Schedule, Schedule.course_id == Course.id)
                .where(
                    Schedule.due_date >= now,
                    Schedule.due_date < horizon,
                    Schedule.type.in_(("exam", "assignment")),
                )
            )
        ).all()

        # 유저 별 카운트 집계
        per_user_todo: dict[UUID, int] = {}
        for uid, _tid, _title in users_with_todos:
            per_user_todo[uid] = per_user_todo.get(uid, 0) + 1

        per_user_sched: dict[UUID, list[tuple[str, str]]] = {}
        for uid, _sid, title, type_ in users_with_schedules:
            per_user_sched.setdefault(uid, []).append((type_, title))

        all_user_ids = set(per_user_todo) | set(per_user_sched)
        if not all_user_ids:
            logger.info("[NOTIFY_DDAY] no upcoming todos/schedules in next 24h")
            return

        sent = 0
        for uid in all_user_ids:
            todo_count = per_user_todo.get(uid, 0)
            sched_list = per_user_sched.get(uid, [])

            parts: list[str] = []
            if sched_list:
                # 가장 먼저: 시험 우선
                sched_list.sort(key=lambda x: 0 if x[0] == "exam" else 1)
                primary_type, primary_title = sched_list[0]
                label = "시험" if primary_type == "exam" else "과제"
                parts.append(f"내일 {label}: {primary_title}")
            if todo_count:
                parts.append(f"오늘 안 끝낼 할 일 {todo_count}개")

            body = " · ".join(parts) if parts else "오늘 일정 확인"

            count = await push_to_user(
                session,
                user_id=uid,
                title="오늘의 학습 알림",
                body=body,
                data={"type": "dday_summary"},
            )
            sent += count
            logger.info("[NOTIFY_DDAY] user=%s pushed=%d body=%r", uid, count, body)

        logger.info("[NOTIFY_DDAY] total_sent=%d for %d users", sent, len(all_user_ids))


# ---------- File classification notifier ----------

@celery_app.task(name="tasks.notify_classified")
def notify_classified_task(file_id: str) -> None:
    """파일 분류 완료 알림. file_tasks._run_classify 후 호출됨."""
    _run_with_fresh_engine(lambda Session: _run_notify_classified(file_id, Session))


async def _run_notify_classified(file_id: str, SessionLocal) -> None:
    async with SessionLocal() as session:
        # file → course → semester → user_id + course_name + file 정보
        row = (
            await session.execute(
                select(File, Course.name, Semester.user_id)
                .join(Course, File.course_id == Course.id)
                .join(Semester, Course.semester_id == Semester.id)
                .where(File.id == UUID(file_id))
            )
        ).first()
        if row is None:
            logger.warning("[NOTIFY_CLASSIFIED] file %s not found", file_id)
            return

        file_row, course_name, user_id = row

        if file_row.status == "classified" and file_row.week:
            title = "자료 분류 완료"
            body = f"{course_name} {file_row.week}주차: {file_row.filename}"
        elif file_row.status == "unclassified":
            title = "분류 필요"
            body = f"{course_name}: '{file_row.filename}' 의 주차를 확인해 주세요"
        else:
            # processing/failed 등 — 알림 안 보냄
            logger.info("[NOTIFY_CLASSIFIED] skip file=%s status=%s", file_id, file_row.status)
            return

        count = await push_to_user(
            session,
            user_id=user_id,
            title=title,
            body=body,
            data={"type": "file_classified", "file_id": str(file_row.id)},
        )
        logger.info("[NOTIFY_CLASSIFIED] file=%s user=%s pushed=%d", file_id, user_id, count)
