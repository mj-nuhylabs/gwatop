import uuid
from fastapi import APIRouter, Depends, status
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select

from app.core.database import get_db
from app.api.v1.dependencies import get_current_user
from app.api.v1.deps_owned import owned_course, owned_semester
from app.models.user import User
from app.models.semester import Semester
from app.models.course import Course
from app.schemas.course import CourseCreate, CourseUpdate, CourseResponse

router = APIRouter(tags=["Courses"])


@router.get("/courses", response_model=list[CourseResponse])
async def list_all_courses(
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """유저의 모든 학기에 걸친 과목을 반환."""
    result = await db.execute(
        select(Course)
        .join(Semester, Course.semester_id == Semester.id)
        .where(Semester.user_id == current_user.id)
        .order_by(Course.name)
    )
    return result.scalars().all()


@router.get("/semesters/{semester_id}/courses", response_model=list[CourseResponse])
async def list_courses(
    semester_id: uuid.UUID,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    await owned_semester(semester_id, current_user, db)
    result = await db.execute(
        select(Course).where(Course.semester_id == semester_id).order_by(Course.name)
    )
    return result.scalars().all()


@router.post("/semesters/{semester_id}/courses", response_model=CourseResponse, status_code=status.HTTP_201_CREATED)
async def create_course(
    semester_id: uuid.UUID,
    body: CourseCreate,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    await owned_semester(semester_id, current_user, db)

    course = Course(
        semester_id=semester_id,
        name=body.name,
        professor=body.professor,
        color=body.color,
        location=body.location,
        schedule=body.schedule,
    )
    db.add(course)
    await db.commit()
    await db.refresh(course)
    return course


@router.get("/courses/{course_id}", response_model=CourseResponse)
async def get_course(
    course_id: uuid.UUID,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    return await owned_course(course_id, current_user, db)


@router.put("/courses/{course_id}", response_model=CourseResponse)
async def update_course(
    course_id: uuid.UUID,
    body: CourseUpdate,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    course = await owned_course(course_id, current_user, db)

    for field, value in body.model_dump(exclude_none=True).items():
        setattr(course, field, value)

    await db.commit()
    await db.refresh(course)
    return course


@router.delete("/courses/{course_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_course(
    course_id: uuid.UUID,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    course = await owned_course(course_id, current_user, db)
    await db.delete(course)
    await db.commit()
