import uuid
from fastapi import APIRouter, Depends, status
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select, update

from app.core.database import get_db
from app.api.v1.dependencies import get_current_user
from app.api.v1.deps_owned import owned_semester
from app.models.user import User
from app.models.semester import Semester
from app.schemas.semester import SemesterCreate, SemesterUpdate, SemesterResponse

router = APIRouter(prefix="/semesters", tags=["Semesters"])


@router.get("", response_model=list[SemesterResponse])
async def list_semesters(
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    result = await db.execute(
        select(Semester)
        .where(Semester.user_id == current_user.id)
        .order_by(Semester.start_date.desc())
    )
    return result.scalars().all()


@router.post("", response_model=SemesterResponse, status_code=status.HTTP_201_CREATED)
async def create_semester(
    body: SemesterCreate,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    if body.is_active:
        await db.execute(
            update(Semester)
            .where(Semester.user_id == current_user.id, Semester.is_active == True)
            .values(is_active=False)
        )

    semester = Semester(
        user_id=current_user.id,
        name=body.name,
        start_date=body.start_date,
        end_date=body.end_date,
        is_active=body.is_active,
    )
    db.add(semester)
    await db.commit()
    await db.refresh(semester)
    return semester


@router.get("/{semester_id}", response_model=SemesterResponse)
async def get_semester(
    semester_id: uuid.UUID,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    return await owned_semester(semester_id, current_user, db)


@router.put("/{semester_id}", response_model=SemesterResponse)
async def update_semester(
    semester_id: uuid.UUID,
    body: SemesterUpdate,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    semester = await owned_semester(semester_id, current_user, db)

    if body.is_active is True:
        await db.execute(
            update(Semester)
            .where(Semester.user_id == current_user.id, Semester.is_active == True, Semester.id != semester_id)
            .values(is_active=False)
        )

    for field, value in body.model_dump(exclude_none=True).items():
        setattr(semester, field, value)

    await db.commit()
    await db.refresh(semester)
    return semester


@router.delete("/{semester_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_semester(
    semester_id: uuid.UUID,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    semester = await owned_semester(semester_id, current_user, db)
    await db.delete(semester)
    await db.commit()


@router.patch("/{semester_id}/set-active", response_model=SemesterResponse)
async def set_active_semester(
    semester_id: uuid.UUID,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    semester = await owned_semester(semester_id, current_user, db)

    await db.execute(
        update(Semester)
        .where(Semester.user_id == current_user.id, Semester.is_active == True)
        .values(is_active=False)
    )

    semester.is_active = True
    await db.commit()
    await db.refresh(semester)
    return semester
