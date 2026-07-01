"""푸시 알림 Celery 태스크.

- `tasks.notify_due_dday` (Beat schedule): 매일 09:00 KST. 두 종류 알림을 동시 발송.
    1) 시험/과제 schedule per-item D-7/D-3/D-1/D-0: 각 시험/과제마다 마감 D-7·D-3·D-1·당일에
       1건씩 폰 푸시. body 에 D-N 라벨 + 과목 + 제목 명시. (과제 탭에는 리마인더 todo 를
       만들지 않고, D-N 리마인더는 오직 이 푸시로만 전달한다.)
    2) 사용자가 직접 만든 todo (`is_auto=False`) 의 D-1 (24h 안) 통합 알림: 사용자
       단위로 묶어 "오늘 안 끝낼 할 일 N개" 한 줄.
   자동 todo (`is_auto=True`) 는 schedule per-item 알림으로 커버되므로 통합 알림 대상 제외.
- `tasks.notify_classified`: 파일 분류 완료 시 소유 유저에게 push. file_tasks.py 호출.

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

# D-N 푸시 대상이 되는 schedule.type 화이트리스트. lecture/meeting/upload/custom 은 알림 안 함.
_NOTIFIABLE_SCHEDULE_TYPES = ("exam", "assignment")
# 시험/과제 마감 **정확히 이 D-N 일에만** 푸시 알림(폰). 과제 탭에는 리마인더 todo 를
# 만들지 않고, D-N 리마인더는 오직 이 푸시로만 전달한다.
# 사용자 선호 cadence: D-7, D-3, D-1, 그리고 당일(D-0).
_DDAY_NOTIFY_DAYS = (7, 3, 1, 0)
_DDAY_MAX_LEAD = max(_DDAY_NOTIFY_DAYS)


@celery_app.task(name="tasks.notify_due_dday")
def notify_due_dday_task() -> None:
    """매일 09:00 KST. D-3 ~ D-0 시험/과제 per-item + 사용자 todo D-1 통합 푸시."""
    _run_with_fresh_engine(_run_notify_due_dday)


async def _run_notify_due_dday(SessionLocal) -> None:
    async with SessionLocal() as session:
        now = kst_now_naive()
        today_start = now.replace(hour=0, minute=0, second=0, microsecond=0)
        # 최대 리드(D-7)까지 조회 후, days_until 이 _DDAY_NOTIFY_DAYS 에 있을 때만 푸시.
        dday_horizon = today_start + timedelta(days=_DDAY_MAX_LEAD + 1)
        next_24h = now + timedelta(hours=24)

        sent_total = 0

        # ----- (1) 시험/과제 schedule per-item D-N 알림 -----
        schedule_rows = (
            await session.execute(
                select(Schedule, Course.name, Semester.user_id)
                .join(Course, Schedule.course_id == Course.id)
                .join(Semester, Course.semester_id == Semester.id)
                .where(
                    Schedule.type.in_(_NOTIFIABLE_SCHEDULE_TYPES),
                    Schedule.due_date >= today_start,
                    Schedule.due_date < dday_horizon,
                )
                .order_by(Schedule.due_date.asc())
            )
        ).all()

        for schedule, course_name, user_id in schedule_rows:
            # 일 단위 D-N 계산. (due_date.date() - today.date()) 의 일수 차.
            days_until = (schedule.due_date.date() - today_start.date()).days
            # 지정된 D-N(7/3/1/0) 일에만 알림. 그 외 날(D-6/5/4/2 등)은 건너뜀.
            if days_until not in _DDAY_NOTIFY_DAYS:
                continue

            type_label = "시험" if schedule.type == "exam" else "과제"
            if days_until == 0:
                dday_label = "오늘"
                title = f"{type_label} 마감일이에요"
            elif days_until == 1:
                dday_label = "내일 (D-1)"
                title = f"{type_label} D-1 알림"
            else:
                dday_label = f"D-{days_until}"
                title = f"{type_label} {dday_label} 알림"

            body = f"[{course_name}] {schedule.title} · {dday_label} 마감"

            count = await push_to_user(
                session,
                user_id=user_id,
                title=title,
                body=body,
                data={
                    "type": "schedule_dday",
                    "schedule_id": str(schedule.id),
                    "schedule_type": schedule.type,
                    "days_until": days_until,
                },
            )
            sent_total += count
            logger.info(
                "[NOTIFY_DDAY] schedule user=%s type=%s D-%d pushed=%d title=%r",
                user_id, schedule.type, days_until, count, schedule.title,
            )

        # ----- (2) 사용자 직접 todo (is_auto=False) D-1 통합 알림 -----
        # is_auto=True 인 자동 D-N todo 는 위 schedule 알림에서 이미 커버되므로 제외.
        user_todo_rows = (
            await session.execute(
                select(Semester.user_id, Todo.id, Todo.title)
                .join(Course, Semester.id == Course.semester_id)
                .join(Todo, Todo.course_id == Course.id)
                .where(
                    Todo.is_done.is_(False),
                    Todo.is_auto.is_(False),
                    Todo.due_date >= now,
                    Todo.due_date < next_24h,
                )
            )
        ).all()

        per_user_todo: dict[UUID, int] = {}
        for uid, _tid, _title in user_todo_rows:
            per_user_todo[uid] = per_user_todo.get(uid, 0) + 1

        for uid, todo_count in per_user_todo.items():
            body = f"오늘 안 끝낼 할 일 {todo_count}개가 있어요"
            count = await push_to_user(
                session,
                user_id=uid,
                title="오늘의 할 일",
                body=body,
                data={"type": "todo_dday_summary"},
            )
            sent_total += count
            logger.info("[NOTIFY_DDAY] todo user=%s count=%d pushed=%d", uid, todo_count, count)

        # push_to_user 가 stage 한 invalid 토큰 삭제를 여기서 일괄 커밋.
        await session.commit()

        if sent_total == 0:
            logger.info("[NOTIFY_DDAY] no notifications sent (no schedules/todos in window)")
        else:
            logger.info(
                "[NOTIFY_DDAY] total_sent=%d (schedule_items=%d, todo_users=%d)",
                sent_total, len(schedule_rows), len(per_user_todo),
            )


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
        # push_to_user 가 stage 한 invalid 토큰 삭제 커밋.
        await session.commit()
        logger.info("[NOTIFY_CLASSIFIED] file=%s user=%s pushed=%d", file_id, user_id, count)
