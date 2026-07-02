"""구독 조회/구독하기/취소.

현재는 PG(결제 게이트웨이) 미연동 — checkout 이 즉시 Pro 를 활성화한다.
토스페이먼츠 등 PG 를 붙일 때는 checkout 을 '결제 준비(주문 생성)' 로 바꾸고,
PG 승인 웹훅/confirm 엔드포인트에서 billing.activate_pro() 를 호출하면 된다.
"""
from typing import Literal

from fastapi import APIRouter, Depends
from pydantic import BaseModel
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.config import settings
from app.core.database import get_db
from app.api.v1.dependencies import get_current_user
from app.models.user import User
from app.services import billing

router = APIRouter(prefix="/billing", tags=["Billing"])


class PricesResponse(BaseModel):
    monthly: int
    monthly_original: int
    yearly_discount_rate: float
    # 연간 결제 시 월 환산가 / 연 총액 (할인 반영).
    yearly_monthly_equivalent: int
    yearly_total: int


class SubscriptionResponse(BaseModel):
    plan: str  # free | pro
    plan_interval: str | None = None
    plan_started_at: str | None = None
    plan_expires_at: str | None = None
    # free 전용 — pro 는 무제한이라 null.
    upload_limit: int | None = None
    upload_used: int
    upload_remaining: int | None = None
    prices: PricesResponse

    @classmethod
    def from_user(cls, u: User) -> "SubscriptionResponse":
        monthly = settings.PRO_MONTHLY_PRICE
        yearly_monthly = round(monthly * (1 - settings.PRO_YEARLY_DISCOUNT_RATE) / 10) * 10
        plan = billing.effective_plan(u)
        is_pro = plan == billing.PLAN_PRO
        return cls(
            plan=plan,
            plan_interval=u.plan_interval if is_pro else None,
            plan_started_at=u.plan_started_at.isoformat() if is_pro and u.plan_started_at else None,
            plan_expires_at=u.plan_expires_at.isoformat() if is_pro and u.plan_expires_at else None,
            upload_limit=billing.upload_limit(u),
            upload_used=u.upload_used or 0,
            upload_remaining=billing.upload_remaining(u),
            prices=PricesResponse(
                monthly=monthly,
                monthly_original=settings.PRO_MONTHLY_ORIGINAL_PRICE,
                yearly_discount_rate=settings.PRO_YEARLY_DISCOUNT_RATE,
                yearly_monthly_equivalent=yearly_monthly,
                yearly_total=yearly_monthly * 12,
            ),
        )


class CheckoutRequest(BaseModel):
    interval: Literal["monthly", "yearly"] = "monthly"


@router.get("/subscription", response_model=SubscriptionResponse)
async def get_subscription(current_user: User = Depends(get_current_user)):
    """현재 플랜 + 업로드 잔여량 + 가격표."""
    return SubscriptionResponse.from_user(current_user)


@router.post("/checkout", response_model=SubscriptionResponse)
async def checkout(
    body: CheckoutRequest,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Pro 구독 시작 (PG 연동 전 — 즉시 활성화). 이미 pro 면 만료일 연장."""
    billing.activate_pro(current_user, body.interval)
    await db.commit()
    await db.refresh(current_user)
    return SubscriptionResponse.from_user(current_user)


@router.post("/cancel", response_model=SubscriptionResponse)
async def cancel(
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """구독 취소 — 즉시 free 플랜으로 전환."""
    billing.cancel_pro(current_user)
    await db.commit()
    await db.refresh(current_user)
    return SubscriptionResponse.from_user(current_user)
