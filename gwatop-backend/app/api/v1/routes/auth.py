from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select
from pydantic import BaseModel, Field, EmailStr
import httpx

from app.core.database import get_db
from app.core.security import (
    hash_password, verify_password,
    create_access_token, create_refresh_token, decode_token,
)
from app.models.user import User
from app.schemas.auth import RegisterRequest, LoginRequest, SocialLoginRequest, RefreshRequest, AuthResponse
from app.api.v1.dependencies import get_current_user
from app.core.config import settings

router = APIRouter(prefix="/auth", tags=["Auth"])


# ---------- 프로필 응답 / 요청 스키마 ----------

class MeResponse(BaseModel):
    id: str
    email: str
    name: str
    provider: str
    created_at: str | None = None

    @classmethod
    def from_user(cls, u: User) -> "MeResponse":
        return cls(
            id=str(u.id),
            email=u.email,
            name=u.name,
            provider=u.provider,
            created_at=u.created_at.isoformat() if u.created_at else None,
        )


class ProfileUpdateRequest(BaseModel):
    name: str | None = Field(None, min_length=1, max_length=60)
    email: EmailStr | None = None


class PasswordChangeRequest(BaseModel):
    current_password: str = Field(..., min_length=1)
    new_password: str = Field(..., min_length=8, max_length=200)


@router.post("/register", response_model=AuthResponse, status_code=201)
async def register(body: RegisterRequest, db: AsyncSession = Depends(get_db)):
    result = await db.execute(select(User).where(User.email == body.email))
    if result.scalar_one_or_none():
        raise HTTPException(409, detail={"error": "email_exists", "message": "이미 존재하는 이메일입니다."})

    user = User(
        email=body.email,
        hashed_password=hash_password(body.password),
        name=body.name,
        school=(body.school or "").strip() or None,
        student_id=(body.student_id or "").strip() or None,
        referral_code=(body.referral_code or "").strip() or None,
    )
    db.add(user)
    await db.commit()
    await db.refresh(user)

    return AuthResponse(
        access_token=create_access_token(str(user.id)),
        refresh_token=create_refresh_token(str(user.id)),
        expires_in=settings.ACCESS_TOKEN_EXPIRE_MINUTES * 60,
        user=user,
    )


@router.post("/login", response_model=AuthResponse)
async def login(body: LoginRequest, db: AsyncSession = Depends(get_db)):
    result = await db.execute(select(User).where(User.email == body.email))
    user = result.scalar_one_or_none()

    if not user or not verify_password(body.password, user.hashed_password):
        raise HTTPException(401, detail={"error": "invalid_credentials", "message": "이메일 또는 비밀번호가 올바르지 않습니다."})

    return AuthResponse(
        access_token=create_access_token(str(user.id)),
        refresh_token=create_refresh_token(str(user.id)),
        expires_in=settings.ACCESS_TOKEN_EXPIRE_MINUTES * 60,
        user=user,
    )


@router.post("/social", response_model=AuthResponse)
async def social_login(body: SocialLoginRequest, db: AsyncSession = Depends(get_db)):
    if body.provider != "google":
        raise HTTPException(400, detail={"error": "unsupported_provider", "message": "Google 로그인만 지원합니다."})

    try:
        async with httpx.AsyncClient(timeout=httpx.Timeout(10.0)) as client:
            resp = await client.get(
                "https://oauth2.googleapis.com/tokeninfo",
                params={"id_token": body.id_token},
            )
    except httpx.HTTPError:
        # 네트워크 오류/타임아웃 — 우리 책임은 아니지만 사용자에게는 401처럼 보이게 한다.
        raise HTTPException(
            503,
            detail={"error": "google_unreachable", "message": "Google 인증 서버에 연결하지 못했어요. 잠시 후 다시 시도해 주세요."},
        )

    if resp.status_code != 200:
        raise HTTPException(401, detail={"error": "invalid_token", "message": "Google 토큰이 유효하지 않습니다."})

    try:
        token_data = resp.json()
    except ValueError:
        raise HTTPException(502, detail={"error": "google_response", "message": "Google 응답을 해석하지 못했어요."})

    # iOS / 웹 / 안드로이드 클라이언트별로 client_id 가 다르므로 set 안에 포함되는지 확인.
    allowed_auds = settings.google_client_ids_set
    if allowed_auds and token_data.get("aud") not in allowed_auds:
        raise HTTPException(401, detail={"error": "invalid_token", "message": "토큰의 대상 앱이 올바르지 않습니다."})

    google_sub = token_data.get("sub")
    email = token_data.get("email")

    if not google_sub or not email:
        raise HTTPException(401, detail={"error": "invalid_token", "message": "Google 계정 정보를 가져올 수 없습니다."})

    name = token_data.get("name") or email.split("@")[0]
    # tokeninfo 는 email_verified 를 문자열 "true"/"false" 또는 bool 로 줄 수 있다.
    email_verified = str(token_data.get("email_verified", "")).lower() == "true"

    result = await db.execute(select(User).where(User.provider == "google", User.provider_id == google_sub))
    user = result.scalar_one_or_none()

    if not user:
        # google sub 로 못 찾으면 같은 이메일의 기존 계정과 병합을 시도한다.
        # 단, Google 이 이메일 소유권을 인증(email_verified)한 경우에만 허용 —
        # 미인증 토큰으로 타인의 email-가입 계정을 탈취하는 것을 막는다.
        email_result = await db.execute(select(User).where(User.email == email))
        existing = email_result.scalar_one_or_none()
        if existing is not None:
            if not email_verified:
                raise HTTPException(
                    401,
                    detail={
                        "error": "email_not_verified",
                        "message": "이메일이 인증된 Google 계정으로만 로그인할 수 있어요.",
                    },
                )
            if existing.provider == "email":
                existing.provider = "google"
                existing.provider_id = google_sub
                await db.commit()
                await db.refresh(existing)
            user = existing

    if user is None:
        user = User(
            email=email,
            name=name,
            provider="google",
            provider_id=google_sub,
            hashed_password=None,
        )
        db.add(user)
        await db.commit()
        await db.refresh(user)

    return AuthResponse(
        access_token=create_access_token(str(user.id)),
        refresh_token=create_refresh_token(str(user.id)),
        expires_in=settings.ACCESS_TOKEN_EXPIRE_MINUTES * 60,
        user=user,
    )


@router.get("/me", response_model=MeResponse)
async def get_me(current_user: User = Depends(get_current_user)):
    """현재 로그인된 사용자 프로필. 토큰 검증을 통해 인증 상태도 확인 가능."""
    return MeResponse.from_user(current_user)


@router.patch("/me", response_model=MeResponse)
async def update_me(
    body: ProfileUpdateRequest,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """이름 / 이메일 수정. 이메일은 unique 검증.
    Social 로그인 사용자도 이름은 자유롭게 수정 가능 (이메일은 잠금).
    """
    if body.name is not None:
        name = body.name.strip()
        if not name:
            raise HTTPException(status.HTTP_400_BAD_REQUEST, detail="이름이 비어 있어요.")
        current_user.name = name

    if body.email is not None:
        new_email = body.email.strip().lower()
        if current_user.provider != "email":
            raise HTTPException(
                status.HTTP_400_BAD_REQUEST,
                detail="소셜 로그인 계정은 이메일을 변경할 수 없어요.",
            )
        if new_email != current_user.email:
            existing = (
                await db.execute(select(User).where(User.email == new_email))
            ).scalar_one_or_none()
            if existing is not None:
                raise HTTPException(
                    status.HTTP_409_CONFLICT,
                    detail="이미 사용 중인 이메일이에요.",
                )
            current_user.email = new_email

    await db.commit()
    await db.refresh(current_user)
    return MeResponse.from_user(current_user)


@router.post("/me/password", status_code=status.HTTP_204_NO_CONTENT)
async def change_password(
    body: PasswordChangeRequest,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """비밀번호 변경. 현재 비밀번호 검증 필수.
    소셜 로그인 사용자는 hashed_password 가 없으므로 거부.
    """
    if current_user.provider != "email" or not current_user.hashed_password:
        raise HTTPException(
            status.HTTP_400_BAD_REQUEST,
            detail="소셜 로그인 계정은 비밀번호를 변경할 수 없어요.",
        )
    if not verify_password(body.current_password, current_user.hashed_password):
        raise HTTPException(
            status.HTTP_401_UNAUTHORIZED,
            detail="현재 비밀번호가 일치하지 않아요.",
        )
    current_user.hashed_password = hash_password(body.new_password)
    await db.commit()
    return None


@router.post("/refresh")
async def refresh_token(body: RefreshRequest, db: AsyncSession = Depends(get_db)):
    try:
        user_id = decode_token(body.refresh_token, expected_type="refresh")
    except Exception:
        raise HTTPException(401, detail={"error": "invalid_token", "message": "리프레시 토큰이 유효하지 않습니다."})

    if not user_id:
        raise HTTPException(401, detail={"error": "invalid_token", "message": "리프레시 토큰이 유효하지 않습니다."})

    result = await db.execute(select(User).where(User.id == user_id))
    user = result.scalar_one_or_none()
    if not user or not user.is_active:
        raise HTTPException(401, detail={"error": "user_not_found", "message": "사용자를 찾을 수 없습니다."})

    new_access_token = create_access_token(str(user.id))
    return {
        "access_token": new_access_token,
        "expires_in": settings.ACCESS_TOKEN_EXPIRE_MINUTES * 60,
    }
