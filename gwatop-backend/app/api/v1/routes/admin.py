"""관리자(테스트용) 라우트.

출시 전 내부 테스트를 위해 한정된 계정에 한해 모든 사용자/파일/일정 데이터를
조회할 수 있게 해주는 엔드포인트 모음. 운영에서는 ADMIN_EMAILS env 가 비어있어야 한다.

게이트:
- 로그인한 사용자의 email 이 settings.ADMIN_EMAILS (콤마 구분) 안에 있어야 통과.
- 없으면 모든 admin 엔드포인트가 404 (존재 자체를 숨김).
"""

from __future__ import annotations

import uuid
from typing import Any

from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy import delete, func, select, update
from sqlalchemy.ext.asyncio import AsyncSession

from app.api.v1.dependencies import get_current_user
from app.core.config import settings
from app.core.database import get_db
from app.models.course import Course
from app.models.device import Device
from app.models.file import File
from app.models.schedule import Schedule
from app.models.semester import Semester
from app.models.todo import Todo
from app.models.user import User

router = APIRouter(prefix="/admin", tags=["Admin"])


# ---------- 게이트 ----------

async def require_admin(
    current_user: User = Depends(get_current_user),
) -> User:
    """현재 사용자가 ADMIN_EMAILS 화이트리스트에 있어야 통과."""
    admins = settings.admin_emails_set
    if not admins:
        # 화이트리스트가 비어있으면 admin 기능 자체를 꺼둔 상태.
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Not Found")
    if (current_user.email or "").lower() not in admins:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Not Found")
    return current_user


# ---------- 개요 ----------

@router.get("/overview")
async def admin_overview(
    _admin: User = Depends(require_admin),
    db: AsyncSession = Depends(get_db),
) -> dict[str, Any]:
    """탭 첫 화면에 보여줄 카운트들."""
    counts: dict[str, int] = {}
    for label, model in [
        ("users", User),
        ("semesters", Semester),
        ("courses", Course),
        ("files", File),
        ("schedules", Schedule),
        ("todos", Todo),
        ("devices", Device),
    ]:
        n = (await db.execute(select(func.count()).select_from(model))).scalar() or 0
        counts[label] = int(n)

    # files 상태 분포
    rows = (await db.execute(
        select(File.status, func.count()).group_by(File.status)
    )).all()
    file_status: dict[str, int] = {str(s): int(c) for s, c in rows}

    return {"counts": counts, "file_status": file_status}


# ---------- 사용자 ----------

@router.get("/users")
async def admin_list_users(
    _admin: User = Depends(require_admin),
    db: AsyncSession = Depends(get_db),
    limit: int = 200,
) -> list[dict[str, Any]]:
    rows = (await db.execute(
        select(User).order_by(User.created_at.desc()).limit(limit)
    )).scalars().all()
    return [
        {
            "id": str(u.id),
            "email": u.email,
            "name": u.name,
            "provider": u.provider,
            "is_active": u.is_active,
            "created_at": u.created_at.isoformat(),
        }
        for u in rows
    ]


@router.get("/users/{user_id}")
async def admin_user_detail(
    user_id: uuid.UUID,
    _admin: User = Depends(require_admin),
    db: AsyncSession = Depends(get_db),
) -> dict[str, Any]:
    """사용자 한 명의 전체 데이터 트리 (학기/과목/파일/일정/할 일/디바이스)."""
    user = (await db.execute(select(User).where(User.id == user_id))).scalar_one_or_none()
    if user is None:
        raise HTTPException(status_code=404, detail="User not found")

    semesters = (await db.execute(
        select(Semester).where(Semester.user_id == user_id).order_by(Semester.start_date.desc())
    )).scalars().all()

    sem_ids = [s.id for s in semesters]
    courses: list[Course] = []
    if sem_ids:
        courses = (await db.execute(
            select(Course).where(Course.semester_id.in_(sem_ids)).order_by(Course.created_at.desc())
        )).scalars().all()
    course_ids = [c.id for c in courses]

    files: list[File] = []
    schedules: list[Schedule] = []
    todos: list[Todo] = []
    if course_ids:
        files = (await db.execute(
            select(File).where(File.course_id.in_(course_ids)).order_by(File.created_at.desc())
        )).scalars().all()
        schedules = (await db.execute(
            select(Schedule).where(Schedule.course_id.in_(course_ids)).order_by(Schedule.due_date.asc())
        )).scalars().all()
        todos = (await db.execute(
            select(Todo).where(Todo.course_id.in_(course_ids)).order_by(Todo.due_date.asc())
        )).scalars().all()

    # uploaded_by_user_id 로 묶인 (course 결정 전) syllabus 도 함께
    standalone_files = (await db.execute(
        select(File).where(
            File.uploaded_by_user_id == user_id,
            File.course_id.is_(None),
        )
    )).scalars().all()
    files = list(files) + list(standalone_files)

    devices = (await db.execute(
        select(Device).where(Device.user_id == user_id).order_by(Device.last_seen_at.desc())
    )).scalars().all()

    return {
        "user": {
            "id": str(user.id),
            "email": user.email,
            "name": user.name,
            "provider": user.provider,
            "is_active": user.is_active,
            "created_at": user.created_at.isoformat(),
        },
        "semesters": [
            {
                "id": str(s.id), "name": s.name,
                "start_date": s.start_date.isoformat(),
                "end_date": s.end_date.isoformat(),
                "is_active": s.is_active,
            } for s in semesters
        ],
        "courses": [
            {
                "id": str(c.id), "semester_id": str(c.semester_id),
                "name": c.name, "professor": c.professor, "color": c.color,
                "schedule_count": len([sc for sc in schedules if sc.course_id == c.id]),
                "file_count": len([f for f in files if f.course_id == c.id]),
            } for c in courses
        ],
        "files": [
            {
                "id": str(f.id),
                "course_id": str(f.course_id) if f.course_id else None,
                "filename": f.filename, "file_type": f.file_type,
                "status": f.status, "week": f.week,
                "is_syllabus": f.is_syllabus,
                "ai_confidence": f.ai_confidence,
                "classification_source": f.classification_source,
                "parse_error": f.parse_error,
                "created_at": f.created_at.isoformat(),
            } for f in files
        ],
        "schedules": [
            {
                "id": str(s.id), "course_id": str(s.course_id),
                "title": s.title, "type": s.type,
                "due_date": s.due_date.isoformat(),
                "is_auto": s.is_auto,
                "description": s.description,
            } for s in schedules
        ],
        "todos": [
            {
                "id": str(t.id),
                "course_id": str(t.course_id),
                "schedule_id": str(t.schedule_id) if t.schedule_id else None,
                "title": t.title, "priority": t.priority,
                "due_date": t.due_date.isoformat(),
                "is_done": t.is_done, "is_auto": t.is_auto,
            } for t in todos
        ],
        "devices": [
            {
                "id": str(d.id), "platform": d.platform,
                "apns_token_preview": (d.apns_token or "")[:16] + "…",
                "last_seen_at": d.last_seen_at.isoformat(),
            } for d in devices
        ],
    }


# ---------- 전역 목록 ----------

@router.get("/files")
async def admin_list_files(
    _admin: User = Depends(require_admin),
    db: AsyncSession = Depends(get_db),
    limit: int = 200,
) -> list[dict[str, Any]]:
    """모든 사용자의 파일을 최근순으로. course/user 이름 join."""
    q = (
        select(
            File, Course.name.label("course_name"),
            User.email.label("user_email"), User.id.label("user_id"),
        )
        .outerjoin(Course, File.course_id == Course.id)
        .outerjoin(Semester, Course.semester_id == Semester.id)
        .outerjoin(User, (Semester.user_id == User.id) | (File.uploaded_by_user_id == User.id))
        .order_by(File.created_at.desc())
        .limit(limit)
    )
    rows = (await db.execute(q)).all()
    out: list[dict[str, Any]] = []
    for row in rows:
        f: File = row[0]
        out.append({
            "id": str(f.id),
            "filename": f.filename, "file_type": f.file_type,
            "status": f.status, "week": f.week,
            "is_syllabus": f.is_syllabus,
            "ai_confidence": f.ai_confidence,
            "classification_source": f.classification_source,
            "parse_error": f.parse_error,
            "course_id": str(f.course_id) if f.course_id else None,
            "course_name": row.course_name,
            "user_id": str(row.user_id) if row.user_id else None,
            "user_email": row.user_email,
            "created_at": f.created_at.isoformat(),
        })
    return out


@router.get("/schedules")
async def admin_list_schedules(
    _admin: User = Depends(require_admin),
    db: AsyncSession = Depends(get_db),
    limit: int = 300,
) -> list[dict[str, Any]]:
    q = (
        select(
            Schedule, Course.name.label("course_name"),
            User.email.label("user_email"),
        )
        .join(Course, Schedule.course_id == Course.id)
        .join(Semester, Course.semester_id == Semester.id)
        .join(User, Semester.user_id == User.id)
        .order_by(Schedule.due_date.asc())
        .limit(limit)
    )
    rows = (await db.execute(q)).all()
    out: list[dict[str, Any]] = []
    for row in rows:
        s: Schedule = row[0]
        out.append({
            "id": str(s.id),
            "title": s.title, "type": s.type,
            "due_date": s.due_date.isoformat(),
            "is_auto": s.is_auto,
            "description": s.description,
            "course_id": str(s.course_id),
            "course_name": row.course_name,
            "user_email": row.user_email,
        })
    return out


@router.get("/todos")
async def admin_list_todos(
    _admin: User = Depends(require_admin),
    db: AsyncSession = Depends(get_db),
    limit: int = 300,
) -> list[dict[str, Any]]:
    q = (
        select(
            Todo, Course.name.label("course_name"),
            User.email.label("user_email"),
        )
        .join(Course, Todo.course_id == Course.id)
        .join(Semester, Course.semester_id == Semester.id)
        .join(User, Semester.user_id == User.id)
        .order_by(Todo.due_date.asc())
        .limit(limit)
    )
    rows = (await db.execute(q)).all()
    out: list[dict[str, Any]] = []
    for row in rows:
        t: Todo = row[0]
        out.append({
            "id": str(t.id),
            "title": t.title,
            "priority": t.priority,
            "due_date": t.due_date.isoformat(),
            "is_done": t.is_done,
            "is_auto": t.is_auto,
            "course_id": str(t.course_id),
            "course_name": row.course_name,
            "user_email": row.user_email,
        })
    return out


# ---------- 삭제 / 리셋 ----------
# 출시 전 테스트용. S3 객체 자체는 지우지 않고 DB row만 제거한다.
# (S3 cleanup은 별도 batch 작업으로 처리 — 운영에서 필요해지면 추가)


async def _delete_files_by_ids(session: AsyncSession, file_ids: list[uuid.UUID]) -> int:
    if not file_ids:
        return 0
    result = await session.execute(delete(File).where(File.id.in_(file_ids)))
    return int(result.rowcount or 0)


async def _delete_auto_schedules_for_courses(
    session: AsyncSession, course_ids: list[uuid.UUID]
) -> tuple[int, int]:
    """course_ids 의 auto schedules + 거기 매달린 auto todos 모두 삭제. (todos, schedules) 개수 반환."""
    if not course_ids:
        return 0, 0
    # FK ondelete=SET NULL이라 schedule만 지우면 auto todo가 orphan으로 남으니 먼저 todo 제거.
    todo_q = await session.execute(
        delete(Todo).where(
            Todo.is_auto.is_(True),
            Todo.schedule_id.in_(
                select(Schedule.id).where(
                    Schedule.course_id.in_(course_ids),
                    Schedule.is_auto.is_(True),
                )
            ),
        )
    )
    sched_q = await session.execute(
        delete(Schedule).where(
            Schedule.course_id.in_(course_ids),
            Schedule.is_auto.is_(True),
        )
    )
    return int(todo_q.rowcount or 0), int(sched_q.rowcount or 0)


@router.delete("/files/{file_id}")
async def admin_delete_file(
    file_id: uuid.UUID,
    _admin: User = Depends(require_admin),
    db: AsyncSession = Depends(get_db),
) -> dict[str, Any]:
    """단일 파일 row 삭제. 강의계획서면 거기서 만들어진 auto schedules/todos도 함께 정리."""
    file_row = (await db.execute(select(File).where(File.id == file_id))).scalar_one_or_none()
    if file_row is None:
        raise HTTPException(status_code=404, detail="File not found")

    counts = {"files_deleted": 0, "schedules_deleted": 0, "todos_deleted": 0}

    # syllabus였다면 그 course의 auto 일정/할 일도 함께 비워주는 게 사용자 의도에 맞다.
    if file_row.is_syllabus and file_row.course_id is not None:
        todos_n, sched_n = await _delete_auto_schedules_for_courses(db, [file_row.course_id])
        counts["todos_deleted"] = todos_n
        counts["schedules_deleted"] = sched_n
        # course 메타도 초기화 (다시 파싱하기 좋게)
        await db.execute(
            update(Course)
            .where(Course.id == file_row.course_id)
            .values(weekly_topics=None, weekly_topic_embeddings=None, schedule=None)
        )

    counts["files_deleted"] = await _delete_files_by_ids(db, [file_id])
    await db.commit()
    return counts


@router.post("/users/{user_id}/syllabus-reset")
async def admin_syllabus_reset(
    user_id: uuid.UUID,
    _admin: User = Depends(require_admin),
    db: AsyncSession = Depends(get_db),
) -> dict[str, Any]:
    """한 사용자의 '강의계획서 업로드 흔적'만 정리.
    - 강의계획서 파일(is_syllabus=true) 모두 삭제
    - 자동 생성된 schedules / todos 삭제
    - course.weekly_topics, weekly_topic_embeddings, schedule (정규 시간) NULL 초기화
    - Course/Semester 자체는 유지, 사용자가 직접 만든 일정/할 일도 유지
    """
    user = (await db.execute(select(User).where(User.id == user_id))).scalar_one_or_none()
    if user is None:
        raise HTTPException(status_code=404, detail="User not found")

    # 이 user의 모든 course id 수집
    course_ids = (await db.execute(
        select(Course.id)
        .join(Semester, Course.semester_id == Semester.id)
        .where(Semester.user_id == user_id)
    )).scalars().all()

    todos_n, sched_n = await _delete_auto_schedules_for_courses(db, list(course_ids))

    # syllabus files (course가 있는 것 + uploaded_by_user_id만 있는 것 모두)
    syllabus_ids = (await db.execute(
        select(File.id).where(
            File.is_syllabus.is_(True),
            ((File.uploaded_by_user_id == user_id) | (File.course_id.in_(course_ids))),
        )
    )).scalars().all()
    files_n = await _delete_files_by_ids(db, list(syllabus_ids))

    courses_reset = 0
    if course_ids:
        r = await db.execute(
            update(Course)
            .where(Course.id.in_(course_ids))
            .values(weekly_topics=None, weekly_topic_embeddings=None, schedule=None)
        )
        courses_reset = int(r.rowcount or 0)

    await db.commit()
    return {
        "user_email": user.email,
        "syllabus_files_deleted": files_n,
        "auto_schedules_deleted": sched_n,
        "auto_todos_deleted": todos_n,
        "courses_reset": courses_reset,
    }


@router.post("/users/{user_id}/full-reset")
async def admin_full_reset(
    user_id: uuid.UUID,
    _admin: User = Depends(require_admin),
    db: AsyncSession = Depends(get_db),
) -> dict[str, Any]:
    """한 사용자의 학습 데이터 전체 리셋 (위험).
    - 모든 파일 삭제 (강의계획서 + 일반 자료)
    - 모든 schedules / todos 삭제 (auto/수동 모두)
    - course.weekly_topics 등 메타 NULL
    - Course/Semester/User 자체는 유지 (재로그인하지 않게)
    """
    user = (await db.execute(select(User).where(User.id == user_id))).scalar_one_or_none()
    if user is None:
        raise HTTPException(status_code=404, detail="User not found")

    course_ids = (await db.execute(
        select(Course.id)
        .join(Semester, Course.semester_id == Semester.id)
        .where(Semester.user_id == user_id)
    )).scalars().all()
    course_ids = list(course_ids)

    todos_n = sched_n = files_n = 0

    if course_ids:
        # cascade 의존성: todos → schedules → files
        r = await db.execute(delete(Todo).where(Todo.course_id.in_(course_ids)))
        todos_n = int(r.rowcount or 0)
        r = await db.execute(delete(Schedule).where(Schedule.course_id.in_(course_ids)))
        sched_n = int(r.rowcount or 0)
        r = await db.execute(delete(File).where(File.course_id.in_(course_ids)))
        files_n = int(r.rowcount or 0)

    # course 미할당 syllabus (uploaded_by_user_id만 있는 것)
    r = await db.execute(
        delete(File).where(
            File.uploaded_by_user_id == user_id,
            File.course_id.is_(None),
        )
    )
    files_n += int(r.rowcount or 0)

    courses_reset = 0
    if course_ids:
        r = await db.execute(
            update(Course)
            .where(Course.id.in_(course_ids))
            .values(weekly_topics=None, weekly_topic_embeddings=None, schedule=None)
        )
        courses_reset = int(r.rowcount or 0)

    await db.commit()
    return {
        "user_email": user.email,
        "files_deleted": files_n,
        "schedules_deleted": sched_n,
        "todos_deleted": todos_n,
        "courses_reset": courses_reset,
    }
