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
from sqlalchemy import func, select
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
