"""학습 탭(Study) 라우트 — AI 콘텐츠 생성/조회 + 사용자 노트 + AI 튜터 채팅.

기존 files.py 의 ai-contents 엔드포인트와 보완 관계:
- files.py 가 제공하던 summary 전용 흐름은 유지
- 이 파일은 quiz/flashcard/mindmap/memorize/topics + scope(페이지 범위) + 노트/튜터 추가
"""

from __future__ import annotations

import logging
import uuid
from typing import Any

from fastapi import APIRouter, Depends, HTTPException, status
from pydantic import BaseModel, Field
from sqlalchemy import and_, delete, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.api.v1.dependencies import get_current_user
from app.api.v1.deps_owned import owned_file
from app.core.database import get_db
from app.models.ai_content import AIContent
from app.models.note import UserNote
from app.models.tutor_message import TutorMessage
from app.models.user import User
from app.services.content_generators import (
    ContentGeneratorError, GENERATOR_REGISTRY, generate_content, slice_text_by_pages,
)
from app.services.tutor import TutorError, ask_tutor

logger = logging.getLogger(__name__)

router = APIRouter(tags=["Study"])


SUPPORTED_TYPES = set(GENERATOR_REGISTRY.keys()) | {"summary"}


def _normalize_scope(pages: str | None) -> str:
    if not pages or pages.strip() in {"", "all"}:
        return "all"
    return pages.strip().replace(" ", "")


# ---------- AI 콘텐츠 ----------

@router.get("/files/{file_id}/ai-contents/{content_type}")
async def study_get_ai_content(
    file_id: uuid.UUID,
    content_type: str,
    pages: str | None = None,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
) -> dict[str, Any]:
    """파일 + content_type + scope(페이지) 조합으로 캐시된 결과 조회.

    같은 파일에 'all', '1-3', '4-7' 처럼 여러 scope 가 공존할 수 있음.
    files.py 의 GET /files/{id}/ai-contents/{type} 와 path 가 같지만, FastAPI 라우터
    매칭 순서상 study.py 가 먼저 등록되도록 main.py 에서 include 순서 정리.
    """
    if content_type not in SUPPORTED_TYPES:
        raise HTTPException(status_code=400, detail=f"Unsupported content_type: {content_type}")

    file_row, _ = await owned_file(file_id, current_user, db)
    scope = _normalize_scope(pages)

    row = (await db.execute(
        select(AIContent).where(
            and_(
                AIContent.file_id == file_row.id,
                AIContent.content_type == content_type,
                AIContent.scope == scope,
            )
        ).order_by(AIContent.generated_at.desc())
    )).scalar_one_or_none()

    if row is None:
        return {
            "file_id": str(file_id),
            "content_type": content_type,
            "scope": scope,
            "status": "pending",
            "content": None,
            "file_status": file_row.status,
        }

    return {
        "file_id": str(file_id),
        "content_type": content_type,
        "scope": scope,
        "status": "ready",
        "content": row.content,
        "generated_at": row.generated_at.isoformat(),
    }


class GenerateRequest(BaseModel):
    pages: str | None = None
    force: bool = False  # True 면 기존 row 삭제 후 재생성


@router.post(
    "/files/{file_id}/ai-contents/{content_type}/generate",
    status_code=status.HTTP_202_ACCEPTED,
)
async def study_generate_ai_content(
    file_id: uuid.UUID,
    content_type: str,
    body: GenerateRequest | None = None,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
) -> dict[str, Any]:
    """비동기 큐잉. Celery 워커가 GPT 호출을 백그라운드에서 처리하고
    결과를 ai_contents 에 저장한다. iOS 는 즉시 202 를 받고 GET 엔드포인트를 폴링.

    이 구조의 장점:
    - 사용자가 다른 탭으로 이동해도 작업이 계속됨
    - Task 취소나 URLSession 타임아웃에 영향 받지 않음
    - 같은 결과가 캐싱돼 있으면 즉시 ready 응답 + 작업 큐잉 안 함
    """
    if content_type not in GENERATOR_REGISTRY:
        raise HTTPException(status_code=400, detail=f"Unsupported content_type: {content_type}")

    file_row, _ = await owned_file(file_id, current_user, db)
    if not file_row.extracted_text:
        raise HTTPException(status_code=400, detail="이 파일은 아직 텍스트 추출이 완료되지 않았어요.")

    req = body or GenerateRequest()
    scope = _normalize_scope(req.pages)

    # 캐시 확인 — 있으면 큐잉 없이 즉시 ready 반환.
    existing = (await db.execute(
        select(AIContent).where(
            and_(
                AIContent.file_id == file_row.id,
                AIContent.content_type == content_type,
                AIContent.scope == scope,
            )
        )
    )).scalar_one_or_none()
    if existing is not None and not req.force:
        return {
            "file_id": str(file_id),
            "content_type": content_type,
            "scope": scope,
            "status": "ready",
            "content": existing.content,
            "generated_at": existing.generated_at.isoformat(),
            "cached": True,
        }

    # Celery 워커로 큐잉. force 일 때 기존 row 는 워커가 안에서 지운다.
    from app.tasks.file_tasks import generate_ai_content_task
    generate_ai_content_task.delay(
        str(file_id), content_type, scope, req.force, str(current_user.id),
    )

    return {
        "file_id": str(file_id),
        "content_type": content_type,
        "scope": scope,
        "status": "queued",
        "content": None,
        "cached": False,
    }


# ---------- 사용자 노트 (CRUD) ----------

class NoteCreate(BaseModel):
    title: str | None = None
    body: str = Field(..., min_length=1, max_length=20000)


class NoteUpdate(BaseModel):
    title: str | None = None
    body: str | None = Field(None, min_length=1, max_length=20000)


def _note_to_dict(n: UserNote) -> dict[str, Any]:
    return {
        "id": str(n.id),
        "file_id": str(n.file_id),
        "title": n.title,
        "body": n.body,
        "created_at": n.created_at.isoformat(),
        "updated_at": n.updated_at.isoformat(),
    }


@router.get("/files/{file_id}/notes")
async def list_notes(
    file_id: uuid.UUID,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
) -> list[dict[str, Any]]:
    await owned_file(file_id, current_user, db)
    rows = (await db.execute(
        select(UserNote).where(
            UserNote.file_id == file_id,
            UserNote.user_id == current_user.id,
        ).order_by(UserNote.created_at.desc())
    )).scalars().all()
    return [_note_to_dict(n) for n in rows]


@router.post("/files/{file_id}/notes", status_code=201)
async def create_note(
    file_id: uuid.UUID,
    body: NoteCreate,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
) -> dict[str, Any]:
    await owned_file(file_id, current_user, db)
    note = UserNote(
        user_id=current_user.id,
        file_id=file_id,
        title=body.title,
        body=body.body,
    )
    db.add(note)
    await db.commit()
    await db.refresh(note)
    return _note_to_dict(note)


@router.patch("/files/{file_id}/notes/{note_id}")
async def update_note(
    file_id: uuid.UUID,
    note_id: uuid.UUID,
    body: NoteUpdate,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
) -> dict[str, Any]:
    await owned_file(file_id, current_user, db)
    note = (await db.execute(
        select(UserNote).where(
            UserNote.id == note_id,
            UserNote.user_id == current_user.id,
            UserNote.file_id == file_id,
        )
    )).scalar_one_or_none()
    if note is None:
        raise HTTPException(status_code=404, detail="Note not found")

    if body.title is not None:
        note.title = body.title
    if body.body is not None:
        note.body = body.body
    await db.commit()
    await db.refresh(note)
    return _note_to_dict(note)


@router.delete("/files/{file_id}/notes/{note_id}", status_code=204)
async def delete_note(
    file_id: uuid.UUID,
    note_id: uuid.UUID,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    await owned_file(file_id, current_user, db)
    result = await db.execute(
        delete(UserNote).where(
            UserNote.id == note_id,
            UserNote.user_id == current_user.id,
            UserNote.file_id == file_id,
        )
    )
    await db.commit()
    if result.rowcount == 0:
        raise HTTPException(status_code=404, detail="Note not found")


# ---------- AI 튜터 ----------

class TutorAskRequest(BaseModel):
    question: str = Field(..., min_length=1, max_length=4000)


def _tutor_message_to_dict(m: TutorMessage) -> dict[str, Any]:
    return {
        "id": str(m.id),
        "role": m.role,
        "body": m.body,
        "tokens": m.tokens,
        "created_at": m.created_at.isoformat(),
    }


@router.get("/files/{file_id}/tutor/messages")
async def list_tutor_messages(
    file_id: uuid.UUID,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
) -> list[dict[str, Any]]:
    await owned_file(file_id, current_user, db)
    rows = (await db.execute(
        select(TutorMessage).where(
            TutorMessage.file_id == file_id,
            TutorMessage.user_id == current_user.id,
        ).order_by(TutorMessage.created_at.asc())
    )).scalars().all()
    return [_tutor_message_to_dict(m) for m in rows]


@router.post("/files/{file_id}/tutor/messages", status_code=201)
async def ask_tutor_endpoint(
    file_id: uuid.UUID,
    body: TutorAskRequest,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
) -> dict[str, Any]:
    """사용자 질문을 저장하고 AI 응답까지 받아서 둘 다 저장 후 반환."""
    file_row, _ = await owned_file(file_id, current_user, db)
    if not file_row.extracted_text:
        raise HTTPException(status_code=400, detail="이 파일은 텍스트 추출이 끝나야 튜터에게 물어볼 수 있어요.")

    # 1) 사용자 메시지 저장
    user_msg = TutorMessage(
        user_id=current_user.id,
        file_id=file_id,
        role="user",
        body=body.question,
    )
    db.add(user_msg)
    await db.commit()
    await db.refresh(user_msg)

    # 2) 히스토리 로드
    history_rows = (await db.execute(
        select(TutorMessage).where(
            TutorMessage.file_id == file_id,
            TutorMessage.user_id == current_user.id,
            TutorMessage.id != user_msg.id,
        ).order_by(TutorMessage.created_at.asc())
    )).scalars().all()
    history = [(m.role, m.body) for m in history_rows]

    # 3) GPT 호출
    try:
        answer, tokens = await ask_tutor(
            file_text=file_row.extracted_text,
            filename=file_row.filename,
            history=history,
            user_question=body.question,
        )
    except TutorError as exc:
        # 실패 시 사용자 메시지는 남기고 assistant 메시지는 안 만든다.
        raise HTTPException(status_code=502, detail=f"AI 응답 실패: {exc}")

    # 4) assistant 메시지 저장
    ai_msg = TutorMessage(
        user_id=current_user.id,
        file_id=file_id,
        role="assistant",
        body=answer,
        tokens=tokens,
    )
    db.add(ai_msg)
    await db.commit()
    await db.refresh(ai_msg)

    return {
        "user_message": _tutor_message_to_dict(user_msg),
        "assistant_message": _tutor_message_to_dict(ai_msg),
    }


@router.delete("/files/{file_id}/tutor/messages", status_code=204)
async def clear_tutor_messages(
    file_id: uuid.UUID,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    await owned_file(file_id, current_user, db)
    await db.execute(
        delete(TutorMessage).where(
            TutorMessage.file_id == file_id,
            TutorMessage.user_id == current_user.id,
        )
    )
    await db.commit()
