"""구독 플랜 판정 + free 플랜 업로드 쿼터.

free: 학습자료 업로드 FREE_UPLOAD_LIMIT 회 (강의계획서는 미카운트).
pro : 무제한. plan_expires_at 경과 시 free 로 레이지 다운그레이드 —
      별도 스케줄러 없이 조회 시점에 effective_plan() 으로 판정한다.

결제 게이트웨이(토스페이먼츠 등) 연동 전까지 checkout 은 즉시 활성화.
PG 를 붙일 때는 routes/billing.py 의 checkout 에서 결제 승인 검증 후
activate_pro() 를 호출하도록 바꾸면 된다.
"""
from datetime import timedelta

from fastapi import HTTPException, status

from app.core.config import settings
from app.core.database import kst_now_naive
from app.models.user import User

PLAN_FREE = "free"
PLAN_PRO = "pro"

# 결제 주기별 유효 기간.
INTERVAL_DAYS = {"monthly": 31, "yearly": 366}


def effective_plan(user: User) -> str:
    """만료를 반영한 현재 플랜. pro 인데 만료됐으면 free."""
    if user.plan == PLAN_PRO:
        if user.plan_expires_at is None or user.plan_expires_at > kst_now_naive():
            return PLAN_PRO
    return PLAN_FREE


def upload_limit(user: User) -> int | None:
    """플랜별 업로드 상한. pro 는 None(무제한)."""
    return None if effective_plan(user) == PLAN_PRO else settings.FREE_UPLOAD_LIMIT


def upload_remaining(user: User) -> int | None:
    limit = upload_limit(user)
    if limit is None:
        return None
    return max(0, limit - (user.upload_used or 0))


def ensure_upload_quota(user: User, count: int = 1) -> None:
    """free 플랜 업로드 잔여량 확인. 부족하면 402 — 프론트가 구독 안내로 연결한다."""
    remaining = upload_remaining(user)
    if remaining is not None and remaining < count:
        raise HTTPException(
            status_code=status.HTTP_402_PAYMENT_REQUIRED,
            detail={
                "error": "upload_limit_reached",
                "message": (
                    f"무료 플랜 업로드 {settings.FREE_UPLOAD_LIMIT}회를 모두 사용했어요. "
                    "Pro 플랜으로 업그레이드하면 무제한 업로드할 수 있어요."
                ),
            },
        )


def consume_upload(user: User, count: int = 1) -> None:
    """업로드 소진 기록. pro 도 카운트는 남기되 제한하지 않는다. 커밋은 호출부 책임."""
    ensure_upload_quota(user, count)
    user.upload_used = (user.upload_used or 0) + count


def activate_pro(user: User, interval: str) -> None:
    """Pro 활성화. interval: monthly | yearly. 이미 pro 면 만료일 연장."""
    now = kst_now_naive()
    was_pro = effective_plan(user) == PLAN_PRO
    base = user.plan_expires_at if was_pro and user.plan_expires_at and user.plan_expires_at > now else now
    user.plan = PLAN_PRO
    user.plan_interval = interval
    user.plan_started_at = user.plan_started_at if was_pro and user.plan_started_at else now
    user.plan_expires_at = base + timedelta(days=INTERVAL_DAYS[interval])


def cancel_pro(user: User) -> None:
    """구독 취소 — 남은 기간 없이 즉시 free 로 전환한다."""
    user.plan = PLAN_FREE
    user.plan_interval = None
    user.plan_started_at = None
    user.plan_expires_at = None
