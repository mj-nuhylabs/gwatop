"""학습 탭(Study) 라우트 — AI 콘텐츠 생성/조회 + 사용자 노트 + AI 튜터 채팅.

기존 files.py 의 ai-contents 엔드포인트와 보완 관계:
- files.py 가 제공하던 summary 전용 흐름은 유지
- 이 파일은 quiz/flashcard/mindmap/memorize/topics + scope(페이지 범위) + 노트/튜터 추가
"""

from __future__ import annotations

import json
import logging
import re
import uuid
from typing import Any

from fastapi import APIRouter, Depends, HTTPException, Query, Response, status
from fastapi.responses import StreamingResponse
from pydantic import BaseModel, Field
from sqlalchemy import and_, delete, select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from app.api.v1.dependencies import get_current_user
from app.api.v1.deps_owned import owned_file
from app.core.database import get_db
from app.models.ai_content import AIContent
from app.models.flashcard_status import UserFlashcardStatus
from app.models.note import UserNote
from app.models.tutor_message import TutorMessage
from app.models.user import User
from app.services.content_generators import (
    ContentGeneratorError, GENERATOR_REGISTRY, generate_content,
    generate_flashcards, slice_text_by_pages,
)
from app.services.tutor import TutorError, ask_tutor, ask_tutor_stream

logger = logging.getLogger(__name__)

router = APIRouter(tags=["Study"])


SUPPORTED_TYPES = set(GENERATOR_REGISTRY.keys()) | {"summary"}

# 튜터 첨부 이미지 정책 — 너무 큰 payload 로 OpenAI 가 거절하기 전에 사전 차단.
MAX_TUTOR_IMAGES = 4
# data URL prefix 매칭. base64 본문 자체는 비검사 (OpenAI 가 reject 시 502 로 전파).
_DATA_URL_RE = re.compile(
    r"^data:image/(png|jpeg|jpg|webp|gif);base64,[A-Za-z0-9+/=\s]+$"
)
# 단일 이미지 최대 크기 (base64 인코딩 후 ~5MB ≒ 원본 ~3.7MB).
MAX_TUTOR_IMAGE_BASE64_BYTES = 5 * 1024 * 1024


def _validate_images(images: list[str] | None) -> list[str]:
    """튜터 첨부 이미지 유효성 검사. data URL 만 허용.

    잘못된 입력은 즉시 422 로 거절 — OpenAI 요청 비용 절약 + 사용자에게 명확한 에러.
    """
    if not images:
        return []
    if len(images) > MAX_TUTOR_IMAGES:
        raise HTTPException(
            status_code=422,
            detail=f"이미지는 최대 {MAX_TUTOR_IMAGES}장까지 첨부할 수 있어요.",
        )
    cleaned: list[str] = []
    for idx, url in enumerate(images):
        if not isinstance(url, str) or not _DATA_URL_RE.match(url):
            raise HTTPException(
                status_code=422,
                detail=f"{idx + 1}번째 이미지가 형식에 맞지 않아요. (data URL 이어야 함)",
            )
        if len(url) > MAX_TUTOR_IMAGE_BASE64_BYTES:
            raise HTTPException(
                status_code=422,
                detail=f"{idx + 1}번째 이미지가 너무 커요 (최대 ~5MB).",
            )
        cleaned.append(url)
    return cleaned


async def _load_user_notes(
    db: AsyncSession, *, file_id: uuid.UUID, user_id: uuid.UUID
) -> list[tuple[str | None, str]]:
    """튜터 컨텍스트로 사용할 사용자 노트 목록. 최신 5개까지.

    학생이 "이 부분이 헷갈려요" 라고 노트에 적었으면 튜터가 그 노트를 참고해서
    답을 조정한다. 너무 많으면 토큰 폭증 → 5개 + tutor.py 내부 길이 제한.
    """
    rows = (await db.execute(
        select(UserNote).where(
            UserNote.file_id == file_id,
            UserNote.user_id == user_id,
        ).order_by(UserNote.updated_at.desc()).limit(5)
    )).scalars().all()
    return [(n.title, n.body) for n in rows]


def _normalize_scope(pages: str | None) -> str:
    if not pages or pages.strip() in {"", "all"}:
        return "all"
    return pages.strip().replace(" ", "")


# ---------- AI 콘텐츠 ----------

@router.get("/files/{file_id}/ai-contents/{content_type}")
async def study_get_ai_content(
    file_id: uuid.UUID,
    content_type: str,
    response: Response,
    pages: str | None = None,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
) -> dict[str, Any]:
    """파일 + content_type + scope(페이지) 조합으로 캐시된 결과 조회.

    같은 파일에 'all', '1-3', '4-7' 처럼 여러 scope 가 공존할 수 있음.
    files.py 의 GET /files/{id}/ai-contents/{type} 와 path 가 같지만, FastAPI 라우터
    매칭 순서상 study.py 가 먼저 등록되도록 main.py 에서 include 순서 정리.

    Cache-Control:
      - ready 상태 (실제 콘텐츠 있음): private, max-age=60 — URLSession 이 1분 캐시
        → 사용자가 탭 왔다 갔다 시 네트워크 요청 0회로 즉시 표시.
      - pending 상태: no-store — 폴링이 매번 fresh 받게.
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
    )).scalars().first()

    if row is None:
        # 아직 생성 안 됨 — 폴링이 곧 다시 호출하므로 캐시 금지.
        response.headers["Cache-Control"] = "no-store"
        return {
            "file_id": str(file_id),
            "content_type": content_type,
            "scope": scope,
            "status": "pending",
            "content": None,
            "file_status": file_row.status,
        }

    # 생성된 결과는 1분간 URLSession 이 캐시 — 같은 file/type/scope 재요청 시 즉시.
    response.headers["Cache-Control"] = "private, max-age=60"
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
    # 퀴즈 한정: 새 퀴즈에서 피하고 싶은 이전 출제 문제 텍스트.
    # iOS '다른 문제로 새 퀴즈' 버튼에서 현재 화면의 문제 목록을 그대로 넘긴다.
    exclude_questions: list[str] | None = None


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
        ).order_by(AIContent.generated_at.desc())
    )).scalars().first()
    if existing is not None and not req.force and not req.exclude_questions:
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
    # exclude_questions 가 있으면 force 와 무관하게 새로 만들어야 함 — 사용자가
    # 명시적으로 '다른 문제로' 를 눌렀기 때문. 캐시 단계에서 이미 통과해 여기까지 왔으므로
    # req.force 가 False 라도 워커는 exclude 힌트를 받아 새 GPT 호출을 수행한다.
    from app.tasks.file_tasks import generate_ai_content_task
    generate_ai_content_task.delay(
        str(file_id), content_type, scope, req.force, str(current_user.id),
        req.exclude_questions,
    )

    return {
        "file_id": str(file_id),
        "content_type": content_type,
        "scope": scope,
        "status": "queued",
        "content": None,
        "cached": False,
    }


# ---------- Speculative prefetch ----------

PREFETCH_TYPES = ("quiz", "flashcard", "mindmap", "memorize", "topics")


@router.post(
    "/files/{file_id}/ai-contents/prefetch",
    status_code=status.HTTP_202_ACCEPTED,
)
async def study_prefetch_ai_contents(
    file_id: uuid.UUID,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
) -> dict[str, Any]:
    """파일 학습 화면 진입 시 iOS 가 호출. 5종 학습 콘텐츠를 '전체 페이지' scope 으로
    백그라운드 큐잉. 이미 ai_contents row 가 있으면 워커가 즉시 skip (force=False).

    사용자가 인트로 화면을 보며 페이지 범위를 고르는 동안 GPT 가 미리 작업해
    '시작' 버튼 클릭 시점엔 캐시 hit 확률이 매우 높아진다.
    """
    file_row, _ = await owned_file(file_id, current_user, db)
    if not file_row.extracted_text or not file_row.extracted_text.strip():
        # 텍스트 추출이 아직이거나 실패. prefetch 의미 없음 — 조용히 통과.
        return {"file_id": str(file_id), "queued": [], "reason": "no_text"}

    from app.tasks.file_tasks import generate_ai_content_task
    for ct in PREFETCH_TYPES:
        generate_ai_content_task.delay(
            str(file_id), ct, "all", False, str(current_user.id),
        )

    return {"file_id": str(file_id), "queued": list(PREFETCH_TYPES)}


# ---------- 플래시카드 상태 (알아요 / 몰라요) ----------

class FlashcardStatusUpdate(BaseModel):
    card_front: str = Field(..., min_length=1, max_length=500)
    # "known" | "unknown" | "none" (none 이면 마킹 제거)
    status: str = Field(..., pattern="^(known|unknown|none)$")
    pages: str | None = None


@router.get("/files/{file_id}/flashcards/status")
async def list_flashcard_status(
    file_id: uuid.UUID,
    pages: str | None = None,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
) -> dict[str, Any]:
    """현재 사용자가 이 파일/scope 에서 마킹한 카드 상태 전체.

    응답: { "statuses": { "<card_front>": "known" | "unknown", ... } }
    iOS 가 플래시카드 시작 시 한 번 호출해 knownIds/unknownIds 초기 상태 복원.
    """
    await owned_file(file_id, current_user, db)
    scope = _normalize_scope(pages)

    rows = (await db.execute(
        select(UserFlashcardStatus).where(
            UserFlashcardStatus.user_id == current_user.id,
            UserFlashcardStatus.file_id == file_id,
            UserFlashcardStatus.scope == scope,
        )
    )).scalars().all()

    return {
        "file_id": str(file_id),
        "scope": scope,
        "statuses": {r.card_front: r.status for r in rows},
    }


@router.put("/files/{file_id}/flashcards/status")
async def set_flashcard_status(
    file_id: uuid.UUID,
    body: FlashcardStatusUpdate,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
) -> dict[str, Any]:
    """카드 한 장 마킹 upsert. status="none" 이면 row 삭제 (마킹 해제).

    iOS 가 사용자가 "알아요"/"몰라요" 누를 때마다 호출. 매번 1 row 라 비용 미미.
    """
    await owned_file(file_id, current_user, db)
    scope = _normalize_scope(body.pages)

    existing = (await db.execute(
        select(UserFlashcardStatus).where(
            UserFlashcardStatus.user_id == current_user.id,
            UserFlashcardStatus.file_id == file_id,
            UserFlashcardStatus.scope == scope,
            UserFlashcardStatus.card_front == body.card_front,
        )
    )).scalar_one_or_none()

    if body.status == "none":
        if existing is not None:
            await db.delete(existing)
            await db.commit()
        return {"file_id": str(file_id), "scope": scope,
                "card_front": body.card_front, "status": None}

    if existing is None:
        existing = UserFlashcardStatus(
            user_id=current_user.id,
            file_id=file_id,
            scope=scope,
            card_front=body.card_front,
            status=body.status,
        )
        db.add(existing)
    else:
        existing.status = body.status

    try:
        await db.commit()
    except IntegrityError:
        # 토글 연타 race — 다른 요청이 같은 카드를 먼저 insert 함. 재조회 후 update.
        await db.rollback()
        existing = (await db.execute(
            select(UserFlashcardStatus).where(
                UserFlashcardStatus.user_id == current_user.id,
                UserFlashcardStatus.file_id == file_id,
                UserFlashcardStatus.scope == scope,
                UserFlashcardStatus.card_front == body.card_front,
            )
        )).scalars().first()
        if existing is not None:
            existing.status = body.status
            await db.commit()
    return {
        "file_id": str(file_id),
        "scope": scope,
        "card_front": body.card_front,
        "status": body.status,
    }


# ---------- 플래시카드 더 만들기 ----------

class FlashcardMoreRequest(BaseModel):
    pages: str | None = None


@router.post("/files/{file_id}/flashcards/more")
async def add_more_flashcards(
    file_id: uuid.UUID,
    body: FlashcardMoreRequest | None = None,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
) -> dict[str, Any]:
    """기존 카드와 겹치지 않는 새 카드를 생성해서 ai_contents 에 append.

    Celery 안 거치고 inline 으로 OpenAI 호출 — 사용자가 명시 트리거한 단발 작업이라
    바로 결과 받는 UX 가 자연스럽다. 호출 동안 약 5~10초 대기.
    """
    file_row, _ = await owned_file(file_id, current_user, db)
    if not file_row.extracted_text:
        raise HTTPException(status_code=400, detail="이 파일은 아직 텍스트 추출이 완료되지 않았어요.")

    req = body or FlashcardMoreRequest()
    scope = _normalize_scope(req.pages)

    existing_row = (await db.execute(
        select(AIContent).where(
            and_(
                AIContent.file_id == file_row.id,
                AIContent.content_type == "flashcard",
                AIContent.scope == scope,
            )
        ).order_by(AIContent.generated_at.desc())
    )).scalars().first()

    existing_cards: list[dict] = []
    if existing_row is not None and isinstance(existing_row.content, dict):
        raw = existing_row.content.get("cards")
        if isinstance(raw, list):
            existing_cards = [c for c in raw if isinstance(c, dict) and c.get("front")]
    exclude_fronts = [c["front"] for c in existing_cards]

    text = slice_text_by_pages(
        file_row.extracted_text, None if scope == "all" else scope
    )
    if not text.strip():
        raise HTTPException(status_code=400, detail="선택한 범위에 분석할 텍스트가 없어요.")

    # 분석본이 있으면 재사용 (file_tasks 와 동일한 캐시 패턴).
    analysis_payload: dict | None = None
    if scope == "all":
        analysis_row = (await db.execute(
            select(AIContent).where(
                AIContent.file_id == file_row.id,
                AIContent.content_type == "analysis",
            ).order_by(AIContent.generated_at.desc())
        )).scalars().first()
        if analysis_row is not None and isinstance(analysis_row.content, dict):
            analysis_payload = analysis_row.content

    try:
        payload = await generate_flashcards(
            text, filename=file_row.filename, analysis=analysis_payload,
            exclude_fronts=exclude_fronts,
        )
    except ContentGeneratorError as exc:
        raise HTTPException(status_code=502, detail=f"AI 생성 실패: {exc}")

    new_cards_raw = payload.get("cards", []) if isinstance(payload, dict) else []
    seen_fronts = {f.strip().lower() for f in exclude_fronts}
    appended: list[dict] = []
    for c in new_cards_raw:
        if not isinstance(c, dict):
            continue
        front = (c.get("front") or "").strip()
        if not front:
            continue
        key = front.lower()
        if key in seen_fronts:
            continue
        seen_fronts.add(key)
        appended.append(c)

    if not appended:
        raise HTTPException(
            status_code=502,
            detail="새로 만들 수 있는 카드가 없어요. 자료가 짧거나 이미 충분히 카드가 있어요.",
        )

    merged_cards = existing_cards + appended
    new_content = {"cards": merged_cards}

    if existing_row is None:
        existing_row = AIContent(
            file_id=file_row.id,
            content_type="flashcard",
            scope=scope,
            content=new_content,
            requested_by_user_id=current_user.id,
        )
        db.add(existing_row)
    else:
        existing_row.content = new_content
    await db.commit()

    return {
        "file_id": str(file_id),
        "scope": scope,
        "status": "ready",
        "content": new_content,
        "added": len(appended),
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
    """튜터 질문 페이로드.

    `images`: 각 원소는 `"data:image/jpeg;base64,..."` 형식 data URL. 최대 4장.
    """
    question: str = Field(..., min_length=1, max_length=4000)
    images: list[str] | None = None


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
    limit: int = Query(200, ge=1, le=500),
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
) -> list[dict[str, Any]]:
    await owned_file(file_id, current_user, db)
    rows = (await db.execute(
        select(TutorMessage).where(
            TutorMessage.file_id == file_id,
            TutorMessage.user_id == current_user.id,
        ).order_by(TutorMessage.created_at.desc()).limit(limit)
    )).scalars().all()
    rows = list(reversed(rows))
    return [_tutor_message_to_dict(m) for m in rows]


@router.post("/files/{file_id}/tutor/messages", status_code=201)
async def ask_tutor_endpoint(
    file_id: uuid.UUID,
    body: TutorAskRequest,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
) -> dict[str, Any]:
    """사용자 질문을 저장하고 AI 응답까지 받아서 둘 다 저장 후 반환.

    이미지 첨부 + 사용자 노트 컨텍스트 자동 주입 지원.
    이미지가 첨부된 경우 사용자 메시지 body 에는 텍스트만 저장하고, 별도로
    `[이미지 N장 첨부]` 라벨을 덧붙여서 히스토리상 시각화한다 (DB 부담 최소화).
    """
    file_row, _ = await owned_file(file_id, current_user, db)
    if not file_row.extracted_text:
        raise HTTPException(status_code=400, detail="이 파일은 텍스트 추출이 끝나야 튜터에게 물어볼 수 있어요.")

    images = _validate_images(body.images)

    # 0) 사용자 노트 로드 — 튜터 답변의 사적인 맥락이 됨.
    user_notes = await _load_user_notes(
        db, file_id=file_id, user_id=current_user.id
    )

    # 1) 사용자 메시지 저장 (이미지 첨부 라벨은 본문에 표시만, 원본은 미저장).
    display_body = body.question
    if images:
        display_body = f"{body.question}\n\n[이미지 {len(images)}장 첨부]"

    user_msg = TutorMessage(
        user_id=current_user.id,
        file_id=file_id,
        role="user",
        body=display_body,
    )
    db.add(user_msg)
    await db.commit()
    await db.refresh(user_msg)

    # 2) 히스토리 로드 (이번 user_msg 제외).
    history_rows_desc = (await db.execute(
        select(TutorMessage).where(
            TutorMessage.file_id == file_id,
            TutorMessage.user_id == current_user.id,
            TutorMessage.id != user_msg.id,
        ).order_by(TutorMessage.created_at.desc()).limit(8)
    )).scalars().all()
    history_rows = list(reversed(history_rows_desc))
    history = [(m.role, m.body) for m in history_rows]

    # 3) GPT 호출
    try:
        answer, tokens = await ask_tutor(
            file_text=file_row.extracted_text,
            filename=file_row.filename,
            history=history,
            user_question=body.question,
            image_data_urls=images or None,
            user_notes=user_notes,
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


@router.post("/files/{file_id}/tutor/messages/stream")
async def ask_tutor_stream_endpoint(
    file_id: uuid.UUID,
    body: TutorAskRequest,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """SSE(Server-Sent Events) 로 튜터 응답을 스트리밍.

    iOS 가 청크 단위로 받아서 점진적으로 화면에 렌더 → 사용자가 기다리는 동안
    진행 상황을 볼 수 있어 체감 latency 가 50% 이상 단축된다.

    스트림 이벤트 형식 (각 라인은 `data: <JSON>\\n\\n`):
      - {"type":"user_message", ...}            ← 사용자 메시지 (DB id 포함)
      - {"type":"start"}                          ← AI 응답 생성 시작
      - {"type":"delta", "text":"..."}           ← 토큰 청크
      - {"type":"done", "assistant_message": {...}}  ← 최종 저장 메시지
      - {"type":"error", "message":"..."}        ← 오류
    """
    file_row, _ = await owned_file(file_id, current_user, db)
    if not file_row.extracted_text:
        raise HTTPException(
            status_code=400, detail="이 파일은 텍스트 추출이 끝나야 튜터에게 물어볼 수 있어요.",
        )

    images = _validate_images(body.images)
    user_notes = await _load_user_notes(
        db, file_id=file_id, user_id=current_user.id
    )

    display_body = body.question
    if images:
        display_body = f"{body.question}\n\n[이미지 {len(images)}장 첨부]"

    user_msg = TutorMessage(
        user_id=current_user.id,
        file_id=file_id,
        role="user",
        body=display_body,
    )
    db.add(user_msg)
    await db.commit()
    await db.refresh(user_msg)

    history_rows_desc = (await db.execute(
        select(TutorMessage).where(
            TutorMessage.file_id == file_id,
            TutorMessage.user_id == current_user.id,
            TutorMessage.id != user_msg.id,
        ).order_by(TutorMessage.created_at.desc()).limit(8)
    )).scalars().all()
    history_rows = list(reversed(history_rows_desc))
    history = [(m.role, m.body) for m in history_rows]

    # 스트림 코루틴 안에서 사용할 값들 (Depends 의 db 는 여기서 끝나므로 별도 세션 새로 연다).
    user_msg_dict = _tutor_message_to_dict(user_msg)
    file_text = file_row.extracted_text
    filename = file_row.filename
    user_id = current_user.id

    async def event_stream():
        from app.core.database import AsyncSessionLocal as async_session_maker

        def pack(payload: dict[str, Any]) -> str:
            return f"data: {json.dumps(payload, ensure_ascii=False)}\n\n"

        # 1) 사용자 메시지 echo
        yield pack({"type": "user_message", "message": user_msg_dict})
        yield pack({"type": "start"})

        chunks: list[str] = []
        try:
            async for delta in ask_tutor_stream(
                file_text=file_text,
                filename=filename,
                history=history,
                user_question=body.question,
                image_data_urls=images or None,
                user_notes=user_notes,
            ):
                chunks.append(delta)
                yield pack({"type": "delta", "text": delta})
        except TutorError as exc:
            yield pack({"type": "error", "message": f"AI 응답 실패: {exc}"})
            return
        except Exception as exc:  # noqa: BLE001
            logger.exception("Unexpected tutor stream error")
            yield pack({"type": "error", "message": f"예기치 못한 오류: {exc}"})
            return

        # 2) 완료 — 누적 텍스트를 DB 에 저장.
        full_answer = "".join(chunks).strip()
        if not full_answer:
            yield pack({"type": "error", "message": "AI 응답이 비어 있어요."})
            return

        async with async_session_maker() as new_db:
            ai_msg = TutorMessage(
                user_id=user_id,
                file_id=file_id,
                role="assistant",
                body=full_answer,
                # 스트림 모드는 usage 가 안 와서 토큰 카운트 미기록. 향후 stream_options 로 보강 가능.
                tokens=None,
            )
            new_db.add(ai_msg)
            await new_db.commit()
            await new_db.refresh(ai_msg)
            ai_msg_dict = _tutor_message_to_dict(ai_msg)

        yield pack({"type": "done", "assistant_message": ai_msg_dict})

    return StreamingResponse(
        event_stream(),
        media_type="text/event-stream",
        headers={
            # SSE 프록시 캐싱 방지 + nginx 버퍼링 무효화.
            "Cache-Control": "no-cache, no-transform",
            "X-Accel-Buffering": "no",
        },
    )


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
