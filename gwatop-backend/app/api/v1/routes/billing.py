"""구독 조회/구독하기(결제)/취소.

결제 흐름 (키가 설정된 PG 를 provider 로 지정했을 때):
  - toss:     checkout(주문 생성) → 프론트 결제창(SDK) → successUrl 리다이렉트
              → POST /billing/toss/confirm → 승인 + Pro 활성화
  - kakaopay: checkout(주문 생성 + ready) → redirect_url 로 이동 → approval_url
              리다이렉트(pg_token) → POST /billing/kakaopay/approve → 승인 + Pro 활성화

PG 키가 없거나 provider 미지정이면 dev 모드 — 주문을 paid 로 남기고 즉시 활성화한다.
.env 에 TOSS_*/KAKAOPAY_* 키를 채우면 코드 수정 없이 실결제로 전환된다.
"""
import uuid
from typing import Literal

from fastapi import APIRouter, Depends, HTTPException, status
from pydantic import BaseModel
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.config import settings
from app.core.database import get_db
from app.api.v1.dependencies import get_current_user
from app.models.user import User
from app.models.payment_order import PaymentOrder
from app.services import billing, payments

router = APIRouter(prefix="/billing", tags=["Billing"])


class PricesResponse(BaseModel):
    monthly: int
    monthly_original: int
    yearly_discount_rate: float
    # 연간 결제 시 월 환산가 / 연 총액 (할인 반영).
    yearly_monthly_equivalent: int
    yearly_total: int


def _prices() -> PricesResponse:
    monthly = settings.PRO_MONTHLY_PRICE
    yearly_monthly = round(monthly * (1 - settings.PRO_YEARLY_DISCOUNT_RATE) / 10) * 10
    return PricesResponse(
        monthly=monthly,
        monthly_original=settings.PRO_MONTHLY_ORIGINAL_PRICE,
        yearly_discount_rate=settings.PRO_YEARLY_DISCOUNT_RATE,
        yearly_monthly_equivalent=yearly_monthly,
        yearly_total=yearly_monthly * 12,
    )


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
    # 키가 설정돼 실결제 가능한 PG 목록. 비어 있으면 프론트가 dev 모드로 안내.
    payment_providers: list[str]

    @classmethod
    def from_user(cls, u: User) -> "SubscriptionResponse":
        plan = billing.effective_plan(u)
        is_pro = plan == billing.PLAN_PRO
        providers = []
        if payments.toss_configured():
            providers.append("toss")
        if payments.kakaopay_configured():
            providers.append("kakaopay")
        return cls(
            plan=plan,
            plan_interval=u.plan_interval if is_pro else None,
            plan_started_at=u.plan_started_at.isoformat() if is_pro and u.plan_started_at else None,
            plan_expires_at=u.plan_expires_at.isoformat() if is_pro and u.plan_expires_at else None,
            upload_limit=billing.upload_limit(u),
            upload_used=u.upload_used or 0,
            upload_remaining=billing.upload_remaining(u),
            prices=_prices(),
            payment_providers=providers,
        )


def _checkout_amount(interval: str) -> tuple[int, str]:
    """주기별 결제 금액 + 주문명. 월간=월 가격, 연간=할인 반영 연 총액 일괄 결제."""
    p = _prices()
    if interval == "yearly":
        return p.yearly_total, "과탑 Pro (연간)"
    return p.monthly, "과탑 Pro (월간)"


class CheckoutRequest(BaseModel):
    interval: Literal["monthly", "yearly"] = "monthly"
    # 미지정 또는 해당 PG 키 미설정 시 dev 모드(즉시 활성화).
    provider: Literal["toss", "kakaopay"] | None = None


class CheckoutResponse(BaseModel):
    mode: Literal["dev_activated", "toss", "redirect"]
    order_id: str | None = None
    amount: int | None = None
    order_name: str | None = None
    # dev_activated 전용 — 즉시 활성화된 구독.
    subscription: SubscriptionResponse | None = None
    # toss 전용 — 프론트 결제창(SDK) 파라미터.
    toss_client_key: str | None = None
    success_url: str | None = None
    fail_url: str | None = None
    # kakaopay 전용 — 결제 페이지 이동 URL.
    redirect_url: str | None = None
    redirect_mobile_url: str | None = None


@router.get("/subscription", response_model=SubscriptionResponse)
async def get_subscription(current_user: User = Depends(get_current_user)):
    """현재 플랜 + 업로드 잔여량 + 가격표 + 사용 가능 PG."""
    return SubscriptionResponse.from_user(current_user)


@router.post("/checkout", response_model=CheckoutResponse)
async def checkout(
    body: CheckoutRequest,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Pro 구독 결제 시작. PG 설정 여부에 따라 실결제 또는 즉시 활성화."""
    amount, order_name = _checkout_amount(body.interval)

    # --- 토스페이먼츠: 주문만 만들고 프론트 결제창 파라미터 반환 ---
    if body.provider == "toss" and payments.toss_configured():
        order = PaymentOrder(
            user_id=current_user.id,
            provider="toss",
            interval=body.interval,
            amount=amount,
            order_name=order_name,
        )
        db.add(order)
        await db.commit()
        await db.refresh(order)
        base = settings.FRONTEND_BASE_URL.rstrip("/")
        return CheckoutResponse(
            mode="toss",
            order_id=str(order.id),
            amount=amount,
            order_name=order_name,
            toss_client_key=settings.TOSS_CLIENT_KEY,
            success_url=f"{base}/settings/subscription?toss=success",
            fail_url=f"{base}/settings/subscription?toss=fail",
        )

    # --- 카카오페이: ready 호출 후 결제 페이지로 리다이렉트 ---
    if body.provider == "kakaopay" and payments.kakaopay_configured():
        order = PaymentOrder(
            user_id=current_user.id,
            provider="kakaopay",
            interval=body.interval,
            amount=amount,
            order_name=order_name,
        )
        db.add(order)
        await db.commit()
        await db.refresh(order)
        ready = await payments.kakaopay_ready(str(order.id), str(current_user.id), order_name, amount)
        order.payment_key = ready["tid"]
        await db.commit()
        return CheckoutResponse(
            mode="redirect",
            order_id=str(order.id),
            amount=amount,
            order_name=order_name,
            redirect_url=ready["redirect_url"],
            redirect_mobile_url=ready.get("redirect_mobile_url"),
        )

    # --- dev 모드: PG 미설정 — 즉시 활성화 (주문은 감사 로그로 남긴다) ---
    order = PaymentOrder(
        user_id=current_user.id,
        provider="dev",
        interval=body.interval,
        amount=amount,
        order_name=order_name,
        status="paid",
    )
    db.add(order)
    billing.activate_pro(current_user, body.interval)
    await db.commit()
    await db.refresh(current_user)
    return CheckoutResponse(
        mode="dev_activated",
        order_id=str(order.id),
        amount=amount,
        order_name=order_name,
        subscription=SubscriptionResponse.from_user(current_user),
    )


async def _load_pending_order(
    order_id: str, provider: str, current_user: User, db: AsyncSession
) -> PaymentOrder:
    try:
        oid = uuid.UUID(order_id)
    except ValueError:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, detail="잘못된 주문 번호예요.")
    order = (
        await db.execute(
            select(PaymentOrder).where(
                PaymentOrder.id == oid,
                PaymentOrder.user_id == current_user.id,
                PaymentOrder.provider == provider,
            )
        )
    ).scalar_one_or_none()
    if order is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, detail="주문을 찾을 수 없어요.")
    if order.status == "paid":
        # 중복 승인(새로고침 등) — 이미 처리됐으니 멱등하게 성공 취급.
        return order
    if order.status != "pending":
        raise HTTPException(status.HTTP_400_BAD_REQUEST, detail="이미 처리된 주문이에요.")
    return order


class TossConfirmRequest(BaseModel):
    order_id: str
    payment_key: str
    amount: int


@router.post("/toss/confirm", response_model=SubscriptionResponse)
async def toss_confirm(
    body: TossConfirmRequest,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """토스 결제 승인 — successUrl 리다이렉트 후 프론트가 호출한다."""
    order = await _load_pending_order(body.order_id, "toss", current_user, db)
    if order.status == "paid":
        return SubscriptionResponse.from_user(current_user)

    # 금액 위변조 방어 — 리다이렉트 쿼리의 amount 를 주문 원본과 대조 (토스 필수 검증).
    if body.amount != order.amount:
        order.status = "failed"
        await db.commit()
        raise HTTPException(status.HTTP_400_BAD_REQUEST, detail="결제 금액이 주문과 일치하지 않아요.")

    try:
        await payments.toss_confirm(body.payment_key, body.order_id, body.amount)
    except HTTPException:
        order.status = "failed"
        await db.commit()
        raise

    order.status = "paid"
    order.payment_key = body.payment_key
    billing.activate_pro(current_user, order.interval)
    await db.commit()
    await db.refresh(current_user)
    return SubscriptionResponse.from_user(current_user)


class KakaopayApproveRequest(BaseModel):
    order_id: str
    pg_token: str


@router.post("/kakaopay/approve", response_model=SubscriptionResponse)
async def kakaopay_approve(
    body: KakaopayApproveRequest,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """카카오페이 결제 승인 — approval_url 리다이렉트 후 프론트가 호출한다."""
    order = await _load_pending_order(body.order_id, "kakaopay", current_user, db)
    if order.status == "paid":
        return SubscriptionResponse.from_user(current_user)
    if not order.payment_key:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, detail="결제 준비 정보가 없어요.")

    try:
        await payments.kakaopay_approve(
            order.payment_key, str(order.id), str(current_user.id), body.pg_token
        )
    except HTTPException:
        order.status = "failed"
        await db.commit()
        raise

    order.status = "paid"
    billing.activate_pro(current_user, order.interval)
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
