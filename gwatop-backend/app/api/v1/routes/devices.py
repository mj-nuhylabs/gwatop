"""디바이스(APNs 푸시 토큰) 등록/해제 엔드포인트."""
from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy import delete, select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from app.api.v1.dependencies import get_current_user
from app.core.database import get_db, kst_now_naive
from app.models.device import Device
from app.models.user import User
from app.schemas.device import DeviceRegisterRequest, DeviceResponse

router = APIRouter(tags=["Devices"])


@router.post("/devices/register", response_model=DeviceResponse, status_code=status.HTTP_201_CREATED)
async def register_device(
    body: DeviceRegisterRequest,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """앱이 APNs 토큰을 받은 직후 호출. 같은 토큰이 다시 들어오면 upsert.

    - 같은 유저가 같은 토큰을 다시 등록 → last_seen_at 갱신
    - 다른 유저가 같은 토큰을 등록 → 기존 row의 owner를 새 유저로 갱신 (디바이스 양도)
    """
    existing = (
        await db.execute(select(Device).where(Device.apns_token == body.apns_token))
    ).scalar_one_or_none()

    if existing:
        existing.user_id = current_user.id
        existing.platform = body.platform
        existing.last_seen_at = kst_now_naive()
        await db.commit()
        await db.refresh(existing)
        return existing

    device = Device(
        user_id=current_user.id,
        apns_token=body.apns_token,
        platform=body.platform,
    )
    db.add(device)
    try:
        await db.commit()
    except IntegrityError:
        # 동시 등록 race — 다른 요청이 같은 apns_token 을 먼저 insert 함.
        # 그 row 를 재조회해 owner/플랫폼을 갱신한다 (디바이스 양도와 동일 처리).
        await db.rollback()
        existing = (
            await db.execute(select(Device).where(Device.apns_token == body.apns_token))
        ).scalar_one_or_none()
        if existing is None:
            raise
        existing.user_id = current_user.id
        existing.platform = body.platform
        existing.last_seen_at = kst_now_naive()
        await db.commit()
        await db.refresh(existing)
        return existing
    await db.refresh(device)
    return device


@router.delete("/devices/{apns_token}", status_code=status.HTTP_204_NO_CONTENT)
async def unregister_device(
    apns_token: str,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """앱 로그아웃 / 알림 끄기 시 호출. 토큰 없는 경우엔 멱등으로 OK."""
    await db.execute(
        delete(Device).where(
            Device.apns_token == apns_token,
            Device.user_id == current_user.id,
        )
    )
    await db.commit()
