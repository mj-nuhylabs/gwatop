import uuid
from datetime import datetime

from fastapi import APIRouter, Depends, Query, status
from sqlalchemy import delete as sa_delete, func, or_, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.api.v1.dependencies import get_current_user
from app.api.v1.deps_owned import owned_course, owned_schedule
from app.core.database import get_db, to_naive_kst
from app.models.course import Course
from app.models.schedule import Schedule
from app.models.semester import Semester
from app.models.user import User
from app.schemas.schedule import (
    CalendarDaySummary,
    CalendarSummaryResponse,
    ExternalEventSyncRequest,
    ExternalEventSyncResult,
    ScheduleCreate,
    ScheduleResponse,
    ScheduleUpdate,
)

router = APIRouter(tags=["Schedules"])


def _to_response(schedule: Schedule, course: Course | None) -> ScheduleResponse:
    return ScheduleResponse(
        id=schedule.id,
        course_id=schedule.course_id,
        course_name=course.name if course else None,
        course_color=course.color if course else None,
        title=schedule.title,
        type=schedule.type,
        due_date=schedule.due_date,
        description=schedule.description,
        is_auto=schedule.is_auto,
        source=schedule.source,
        external_id=schedule.external_id,
        created_at=schedule.created_at,
    )


# 과목 일정(course→semester→user) + 외부 일정(schedule.user_id) 둘 다 현재 유저 소유로 잡는 필터.
def _owned_by(user_id) -> object:
    return or_(Semester.user_id == user_id, Schedule.user_id == user_id)


@router.get("/schedules", response_model=list[ScheduleResponse])
async def list_schedules(
    start: datetime | None = Query(None, description="ISO datetime, inclusive"),
    end: datetime | None = Query(None, description="ISO datetime, exclusive"),
    course_id: uuid.UUID | None = Query(None, description="Filter by course"),
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    # iOS 가 'Z' (UTC) 붙은 ISO 보내면 tz-aware datetime — DB 컬럼은 naive 라 비교 실패.
    start = to_naive_kst(start)
    end = to_naive_kst(end)

    # 외부(Apple) 일정은 course 가 없으므로 outerjoin + (semester.user OR schedule.user) 로 소유 판정.
    stmt = (
        select(Schedule, Course.name, Course.color)
        .outerjoin(Course, Schedule.course_id == Course.id)
        .outerjoin(Semester, Course.semester_id == Semester.id)
        .where(_owned_by(current_user.id))
        .order_by(Schedule.due_date.asc())
    )
    if start is not None:
        stmt = stmt.where(Schedule.due_date >= start)
    if end is not None:
        stmt = stmt.where(Schedule.due_date < end)
    if course_id is not None:
        stmt = stmt.where(Schedule.course_id == course_id)

    rows = (await db.execute(stmt)).all()
    return [
        ScheduleResponse(
            id=s.id,
            course_id=s.course_id,
            course_name=name,
            course_color=color,
            title=s.title,
            type=s.type,
            due_date=s.due_date,
            description=s.description,
            is_auto=s.is_auto,
            source=s.source,
            external_id=s.external_id,
            created_at=s.created_at,
        )
        for s, name, color in rows
    ]


@router.get("/schedules/calendar/summary", response_model=CalendarSummaryResponse)
async def calendar_summary(
    start: datetime = Query(..., description="ISO datetime, inclusive"),
    end: datetime = Query(..., description="ISO datetime, exclusive"),
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """월간/주간 캘린더 점 표시용. 일별 type별 count만 반환 (payload 가벼움)."""
    # tz-aware → naive KST 변환 (DB 컬럼이 naive 라 직접 비교 불가)
    start_n = to_naive_kst(start) or start
    end_n = to_naive_kst(end) or end

    day = func.date(Schedule.due_date)
    stmt = (
        select(day.label("day"), Schedule.type, func.count().label("cnt"))
        .outerjoin(Course, Schedule.course_id == Course.id)
        .outerjoin(Semester, Course.semester_id == Semester.id)
        .where(
            _owned_by(current_user.id),
            Schedule.due_date >= start_n,
            Schedule.due_date < end_n,
        )
        .group_by(day, Schedule.type)
        .order_by(day)
    )
    rows = (await db.execute(stmt)).all()

    by_day: dict[str, dict[str, int]] = {}
    for d, t, cnt in rows:
        key = d.isoformat() if hasattr(d, "isoformat") else str(d)
        by_day.setdefault(key, {})[t] = cnt

    days = [
        CalendarDaySummary(date=k, total=sum(v.values()), by_type=v)
        for k, v in sorted(by_day.items())
    ]
    return CalendarSummaryResponse(start=start, end=end, days=days)


@router.post("/schedules", response_model=ScheduleResponse, status_code=status.HTTP_201_CREATED)
async def create_schedule(
    body: ScheduleCreate,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    # lazy import: schedules <-> todos 양방향 import 회피
    from app.api.v1.routes.todos import replace_auto_todos_for_schedule

    course = await owned_course(body.course_id, current_user, db)

    schedule = Schedule(
        course_id=body.course_id,
        title=body.title,
        type=body.type,
        due_date=body.due_date,
        description=body.description,
        is_auto=False,  # 수동 추가
    )
    db.add(schedule)
    await db.flush()  # schedule.id 확보 후 auto todos 생성
    await replace_auto_todos_for_schedule(db, schedule)
    await db.commit()
    await db.refresh(schedule)
    return _to_response(schedule, course)


@router.put("/schedules/{schedule_id}", response_model=ScheduleResponse)
async def update_schedule(
    schedule_id: uuid.UUID,
    body: ScheduleUpdate,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    from app.api.v1.routes.todos import replace_auto_todos_for_schedule  # lazy

    schedule, course = await owned_schedule(schedule_id, current_user, db)

    # course_id를 바꾸려면 새 course도 유저 소유여야 함
    if body.course_id is not None and body.course_id != schedule.course_id:
        course = await owned_course(body.course_id, current_user, db)
        schedule.course_id = body.course_id

    for field in ("title", "type", "due_date", "description"):
        value = getattr(body, field)
        if value is not None:
            setattr(schedule, field, value)

    await db.flush()
    await replace_auto_todos_for_schedule(db, schedule)
    await db.commit()
    await db.refresh(schedule)
    return _to_response(schedule, course)


@router.delete("/schedules/{schedule_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_schedule(
    schedule_id: uuid.UUID,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    from app.models.todo import Todo
    from sqlalchemy import delete as sa_delete

    schedule, _ = await owned_schedule(schedule_id, current_user, db)
    # auto todos는 함께 삭제, 수동 todos는 FK ondelete=SET NULL로 유지 (link만 끊김)
    await db.execute(
        sa_delete(Todo).where(
            Todo.schedule_id == schedule.id,
            Todo.is_auto.is_(True),
        )
    )
    await db.delete(schedule)
    await db.commit()


@router.post("/schedules/external/sync", response_model=ExternalEventSyncResult)
async def sync_external_events(
    body: ExternalEventSyncRequest,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """외부(Apple 캘린더) 일정 전체 스냅샷을 받아 전치환(upsert + 누락분 삭제)한다.

    - external_id 로 기존 행 매칭 → 변경분만 update, 없으면 create.
    - 이번 스냅샷에 없는 같은 source 의 기존 외부 일정은 삭제(Apple 에서 지운 일정 반영).
    - 토글 OFF 시 앱이 events=[] 로 호출하면 해당 source 외부 일정이 전부 삭제된다.
    외부 개인 일정엔 auto todo 를 만들지 않는다(start_date 만 due_date 로 저장, end 는 보관 안 함).
    """
    source = body.source or "apple_calendar"

    existing = (
        await db.execute(
            select(Schedule).where(
                Schedule.user_id == current_user.id,
                Schedule.source == source,
            )
        )
    ).scalars().all()
    by_ext = {s.external_id: s for s in existing if s.external_id}

    created = updated = 0
    seen: set[str] = set()
    for ev in body.events:
        seen.add(ev.external_id)
        due = to_naive_kst(ev.start_date) or ev.start_date
        title = ev.title.strip() or "(제목 없음)"
        desc = (ev.location or None)
        row = by_ext.get(ev.external_id)
        if row is None:
            db.add(
                Schedule(
                    course_id=None,
                    user_id=current_user.id,
                    title=title,
                    type="meeting",
                    due_date=due,
                    description=desc,
                    is_auto=False,
                    source=source,
                    external_id=ev.external_id,
                )
            )
            created += 1
        else:
            if (row.title, row.due_date, row.description) != (title, due, desc):
                row.title, row.due_date, row.description = title, due, desc
                updated += 1

    stale_ids = [s.id for s in existing if (s.external_id or "") not in seen]
    deleted = 0
    if stale_ids:
        await db.execute(sa_delete(Schedule).where(Schedule.id.in_(stale_ids)))
        deleted = len(stale_ids)

    await db.commit()
    return ExternalEventSyncResult(created=created, updated=updated, deleted=deleted)
