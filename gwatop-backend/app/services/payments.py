"""토스페이먼츠 / 카카오페이 API 클라이언트.

키(config)가 비어 있으면 configured=False — routes/billing.py 가 dev 모드(즉시 활성화)로
폴백한다. .env 에 키를 채우면 코드 수정 없이 실결제 흐름으로 전환된다.

- 토스페이먼츠: 프론트 결제창(SDK, clientKey) → successUrl 리다이렉트 →
  백엔드가 secretKey 로 승인(confirm) 호출. https://docs.tosspayments.com
- 카카오페이: 백엔드 ready → 사용자를 redirect_url 로 보냄 → approval_url 에
  pg_token 리다이렉트 → 백엔드 approve 호출. https://developers.kakaopay.com
"""
import base64
import logging

import httpx
from fastapi import HTTPException, status

from app.core.config import settings

logger = logging.getLogger(__name__)

TOSS_API_BASE = "https://api.tosspayments.com"
KAKAOPAY_API_BASE = "https://open-api.kakaopay.com"

_TIMEOUT = httpx.Timeout(15.0)


def toss_configured() -> bool:
    return bool(settings.TOSS_CLIENT_KEY and settings.TOSS_SECRET_KEY)


def kakaopay_configured() -> bool:
    return bool(settings.KAKAOPAY_SECRET_KEY and settings.KAKAOPAY_CID)


def _toss_auth_header() -> dict[str, str]:
    # 토스는 Basic 인증 — secretKey 뒤에 ":" 를 붙여 base64.
    token = base64.b64encode(f"{settings.TOSS_SECRET_KEY}:".encode()).decode()
    return {"Authorization": f"Basic {token}"}


def _kakaopay_auth_header() -> dict[str, str]:
    return {"Authorization": f"SECRET_KEY {settings.KAKAOPAY_SECRET_KEY}"}


def _pg_error(provider: str, resp: httpx.Response) -> HTTPException:
    logger.error("%s 결제 API 오류 status=%s body=%s", provider, resp.status_code, resp.text[:500])
    return HTTPException(
        status_code=status.HTTP_402_PAYMENT_REQUIRED,
        detail={"error": "payment_failed", "message": "결제 승인에 실패했어요. 다시 시도해 주세요."},
    )


async def toss_confirm(payment_key: str, order_id: str, amount: int) -> dict:
    """토스 결제 승인. 결제창 성공 리다이렉트 후 반드시 서버에서 호출해야 결제가 확정된다."""
    async with httpx.AsyncClient(timeout=_TIMEOUT) as client:
        resp = await client.post(
            f"{TOSS_API_BASE}/v1/payments/confirm",
            headers=_toss_auth_header(),
            json={"paymentKey": payment_key, "orderId": order_id, "amount": amount},
        )
    if resp.status_code != 200:
        raise _pg_error("toss", resp)
    return resp.json()


async def kakaopay_ready(
    order_id: str,
    user_id: str,
    order_name: str,
    amount: int,
) -> dict:
    """카카오페이 결제 준비. tid + 사용자를 보낼 redirect URL 을 받는다."""
    base = settings.FRONTEND_BASE_URL.rstrip("/")
    async with httpx.AsyncClient(timeout=_TIMEOUT) as client:
        resp = await client.post(
            f"{KAKAOPAY_API_BASE}/online/v1/payment/ready",
            headers=_kakaopay_auth_header(),
            json={
                "cid": settings.KAKAOPAY_CID,
                "partner_order_id": order_id,
                "partner_user_id": user_id,
                "item_name": order_name,
                "quantity": 1,
                "total_amount": amount,
                "tax_free_amount": 0,
                "approval_url": f"{base}/settings/subscription?kakaopay=success&order_id={order_id}",
                "cancel_url": f"{base}/settings/subscription?kakaopay=cancel",
                "fail_url": f"{base}/settings/subscription?kakaopay=fail",
            },
        )
    if resp.status_code != 200:
        raise _pg_error("kakaopay", resp)
    data = resp.json()
    return {
        "tid": data["tid"],
        # PC 웹 기준. 모바일 웹은 next_redirect_mobile_url — 프론트가 UA 로 고를 수 있게 둘 다 반환.
        "redirect_url": data["next_redirect_pc_url"],
        "redirect_mobile_url": data.get("next_redirect_mobile_url"),
    }


async def kakaopay_approve(tid: str, order_id: str, user_id: str, pg_token: str) -> dict:
    """카카오페이 결제 승인. approval_url 로 받은 pg_token 으로 확정한다."""
    async with httpx.AsyncClient(timeout=_TIMEOUT) as client:
        resp = await client.post(
            f"{KAKAOPAY_API_BASE}/online/v1/payment/approve",
            headers=_kakaopay_auth_header(),
            json={
                "cid": settings.KAKAOPAY_CID,
                "tid": tid,
                "partner_order_id": order_id,
                "partner_user_id": user_id,
                "pg_token": pg_token,
            },
        )
    if resp.status_code != 200:
        raise _pg_error("kakaopay", resp)
    return resp.json()
