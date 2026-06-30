"""강의계획서 갱신 후보(변경 탐지 결과)의 조회/승인/거부 (Stage 3).

핵심 원칙: 변경 사항은 **자동 반영 금지**. pending 제안을 사용자에게 보여주고,
승인(approve)한 항목만 이 라우트에서 Course/Schedule 에 실제 반영한다.
"""
import logging
import uuid

from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.api.v1.dependencies import get_current_user
from app.api.v1.deps_owned import owned_proposal
from app.core.database import get_db
from app.models.course import Course
from app.models.schedule import Schedule
from app.models.semester import Semester
from app.models.syllabus_update_proposal import SyllabusUpdateProposal
from app.models.user import User
from app.schemas.syllabus_update_proposal import FIELD_LABELS, ProposalResponse
from app.services.change_detector import parse_class_time, parse_due_date

logger = logging.getLogger(__name__)

router = APIRouter(tags=["UpdateProposals"])


def _to_response(p: SyllabusUpdateProposal, course_name: str | None) -> ProposalResponse:
    return ProposalResponse(
        id=p.id,
        course_id=p.course_id,
        course_name=course_name,
        file_id=p.file_id,
        schedule_id=p.schedule_id,
        field=p.field,
        field_label=FIELD_LABELS.get(p.field, p.field),
        target_title=p.target_title,
        old_value=p.old_value,
        new_value=p.new_value,
        evidence=p.evidence,
        confidence=p.confidence,
        status=p.status,
        created_at=p.created_at,
    )


@router.get("/update-proposals", response_model=list[ProposalResponse])
async def list_update_proposals(
    status_filter: str = "pending",
    course_id: uuid.UUID | None = None,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """현재 사용자의 강의계획서 갱신 후보 목록. 기본은 pending 만.

    course_id 를 주면 해당 과목으로 필터(과목 상세 화면용).
    """
    q = (
        select(SyllabusUpdateProposal, Course.name)
        .join(Course, SyllabusUpdateProposal.course_id == Course.id)
        .join(Semester, Course.semester_id == Semester.id)
        .where(Semester.user_id == current_user.id)
        .order_by(SyllabusUpdateProposal.created_at.desc())
    )
    if status_filter and status_filter != "all":
        q = q.where(SyllabusUpdateProposal.status == status_filter)
    if course_id is not None:
        q = q.where(SyllabusUpdateProposal.course_id == course_id)

    rows = (await db.execute(q)).all()
    return [_to_response(p, name) for p, name in rows]


@router.post("/update-proposals/{proposal_id}/approve", response_model=ProposalResponse)
async def approve_update_proposal(
    proposal_id: uuid.UUID,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """제안을 승인하고 강의계획서(Course/Schedule)에 실제 반영한다.

    - classroom        → course.location 갱신
    - class_time       → course.schedule(시간표) 갱신 (요일/시작/종료 파싱)
    - assignment_due   → 대상 일정의 due_date 갱신 (날짜 파싱)
    파싱/대상 매칭에 실패하면 반영하지 않고 422 — pending 으로 남겨 사용자가
    직접 수정하도록 안내한다(잘못된 자동 반영 방지).
    """
    proposal, course = await owned_proposal(proposal_id, current_user, db)
    if proposal.status != "pending":
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail=f"이미 처리된 제안입니다 (status={proposal.status}).",
        )

    if proposal.field == "classroom":
        course.location = proposal.new_value.strip() or course.location

    elif proposal.field == "class_time":
        parsed = parse_class_time(proposal.new_value)
        if parsed is None:
            raise HTTPException(
                status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
                detail="강의시간 형식을 인식하지 못했어요. 예: '월 14:00-15:30'. 직접 수정해 주세요.",
            )
        course.schedule = _merge_class_time(course.schedule, parsed)

    elif proposal.field == "assignment_due":
        if proposal.schedule_id is None:
            raise HTTPException(
                status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
                detail="변경할 대상 일정을 찾지 못했어요. 캘린더에서 직접 수정해 주세요.",
            )
        schedule = await db.get(Schedule, proposal.schedule_id)
        if schedule is None:
            raise HTTPException(
                status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
                detail="대상 일정이 더 이상 존재하지 않아요.",
            )
        due = parse_due_date(proposal.new_value, schedule.due_date.year)
        if due is None:
            raise HTTPException(
                status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
                detail="마감 날짜를 인식하지 못했어요. 예: '2025-04-15' 또는 '4월 15일'. 직접 수정해 주세요.",
            )
        schedule.due_date = due

    else:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=f"알 수 없는 변경 유형: {proposal.field}",
        )

    proposal.status = "approved"
    await db.commit()
    await db.refresh(proposal)
    logger.info(
        "proposal approved id=%s course=%s field=%s new=%r",
        proposal.id, course.id, proposal.field, proposal.new_value,
    )
    return _to_response(proposal, course.name)


@router.post("/update-proposals/{proposal_id}/reject", response_model=ProposalResponse)
async def reject_update_proposal(
    proposal_id: uuid.UUID,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """제안을 거부(무시). DB 에는 아무 반영도 하지 않는다."""
    proposal, course = await owned_proposal(proposal_id, current_user, db)
    if proposal.status != "pending":
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail=f"이미 처리된 제안입니다 (status={proposal.status}).",
        )
    proposal.status = "rejected"
    await db.commit()
    await db.refresh(proposal)
    return _to_response(proposal, course.name)


def _merge_class_time(schedule: list | None, parsed: dict) -> list:
    """같은 요일 슬롯이 있으면 시간만 교체, 단일 슬롯이면 통째 교체, 아니면 추가.

    새 list 객체를 반환해 SQLAlchemy(JSON 컬럼) 변경 감지를 확실히 트리거한다.
    """
    slots = [dict(s) for s in (schedule or [])]
    for s in slots:
        if s.get("day") == parsed["day"]:
            s["start_time"] = parsed["start_time"]
            s["end_time"] = parsed["end_time"]
            return slots
    if len(slots) == 1:
        return [parsed]
    slots.append(parsed)
    return slots
