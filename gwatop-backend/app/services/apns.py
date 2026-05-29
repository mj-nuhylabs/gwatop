"""APNs 푸시 알림 서비스.

설계 원칙:
- 환경변수(APNS_KEY_ID/TEAM_ID/KEY_PATH/BUNDLE_ID) 중 하나라도 비어 있으면 **placeholder mode**.
  로그만 찍고 네트워크 호출 안 함. 데모 환경에서 안전하게 import + 호출 가능.
- 모두 채워지면 aioapns 클라이언트로 실제 HTTP/2 push.
- 호출자는 placeholder/real 모드를 신경 쓰지 않음 — `push_to_user(...)` 한 함수로 통일.
- 토큰이 invalid (BadDeviceToken 등)면 devices 테이블에서 해당 row 삭제.
"""
from __future__ import annotations

import asyncio
import logging
from typing import Any
from uuid import UUID

from sqlalchemy import delete, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.config import settings
from app.models.device import Device

logger = logging.getLogger(__name__)


def _is_configured() -> bool:
    return bool(
        settings.APNS_KEY_ID
        and settings.APNS_TEAM_ID
        and settings.APNS_KEY_PATH
        and settings.APNS_BUNDLE_ID
    )


# aioapns 클라이언트는 진짜 환경일 때만 lazy init. 이벤트 루프별로 캐시한다.
_client_singleton: Any | None = None
_client_loop: asyncio.AbstractEventLoop | None = None


def _get_client() -> Any | None:
    """real mode 클라이언트 가져오기. 미설정/import 실패 시 None.

    Celery 는 태스크마다 새 asyncio.run() 루프를 만든다. aioapns 의 HTTP/2 연결은
    생성 시점 루프에 묶이므로, 다른 루프에서 재사용하면 죽은 루프 참조로 실패한다.
    루프가 바뀌면 클라이언트를 새로 만든다(같은 태스크 안에서는 캐시 재사용).
    """
    global _client_singleton, _client_loop
    if not _is_configured():
        return None
    try:
        loop = asyncio.get_running_loop()
    except RuntimeError:
        loop = None
    if _client_singleton is not None and _client_loop is loop:
        return _client_singleton
    try:
        from aioapns import APNs
        _client_singleton = APNs(
            key=settings.APNS_KEY_PATH,
            key_id=settings.APNS_KEY_ID,
            team_id=settings.APNS_TEAM_ID,
            topic=settings.APNS_BUNDLE_ID,
            use_sandbox=not settings.APNS_PRODUCTION,
        )
        _client_loop = loop
        return _client_singleton
    except ImportError:
        logger.warning("[APNS] aioapns not installed — placeholder mode")
        return None
    except Exception:
        logger.exception("[APNS] failed to init APNs client — placeholder mode")
        return None


async def _send_one(token: str, title: str, body: str, data: dict[str, Any]) -> tuple[bool, str | None]:
    """단일 토큰에 push. 성공 (True, None), 실패 (False, error_code)."""
    client = _get_client()
    if client is None:
        # placeholder — 실제 호출 없이 로그만
        logger.info(
            "[APNS-NOOP] token=%s... title=%r body=%r data=%s",
            token[:12], title, body, data,
        )
        return True, None

    try:
        from aioapns import NotificationRequest, PushType  # type: ignore

        payload = {
            "aps": {"alert": {"title": title, "body": body}, "sound": "default"},
            **data,
        }
        request = NotificationRequest(
            device_token=token,
            message=payload,
            push_type=PushType.ALERT,
        )
        response = await client.send_notification(request)
        if response.is_successful:
            return True, None
        # 토큰 무효 등 — 호출자가 토큰 삭제 처리
        logger.warning("[APNS] push failed token=%s... reason=%s", token[:12], response.description)
        return False, response.description or "unknown"
    except Exception as exc:
        logger.exception("[APNS] send error token=%s...", token[:12])
        return False, str(exc)[:200]


# Apple이 토큰을 폐기했을 때 반환하는 에러 코드들. 받으면 즉시 DB에서 토큰 삭제.
_INVALID_TOKEN_REASONS = {"BadDeviceToken", "Unregistered", "DeviceTokenNotForTopic"}


async def push_to_user(
    db: AsyncSession,
    user_id: UUID,
    title: str,
    body: str,
    data: dict[str, Any] | None = None,
) -> int:
    """유저의 모든 등록된 디바이스로 푸시. 성공한 디바이스 개수 반환.

    invalid 토큰은 자동으로 devices 테이블에서 제거.
    """
    data = data or {}
    devices = (
        await db.execute(select(Device).where(Device.user_id == user_id))
    ).scalars().all()

    if not devices:
        logger.info("[APNS] no devices for user=%s — skip", user_id)
        return 0

    success = 0
    invalid_ids: list[UUID] = []
    for dev in devices:
        ok, reason = await _send_one(dev.apns_token, title, body, data)
        if ok:
            success += 1
        elif reason in _INVALID_TOKEN_REASONS:
            invalid_ids.append(dev.id)

    if invalid_ids:
        # invalid 토큰 삭제는 호출자 세션에 stage 만 한다 — commit 은 호출자 책임.
        # 서비스가 호출자 세션을 직접 commit 하면 호출자의 다른 미커밋 변경까지 함께
        # 커밋되어 트랜잭션 경계가 깨진다.
        await db.execute(delete(Device).where(Device.id.in_(invalid_ids)))
        logger.info("[APNS] staged purge of %d invalid tokens for user=%s", len(invalid_ids), user_id)

    return success
