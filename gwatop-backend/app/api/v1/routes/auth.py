from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select
import httpx

from app.core.database import get_db
from app.core.security import (
    hash_password, verify_password,
    create_access_token, create_refresh_token, decode_token,
)
from app.models.user import User
from app.schemas.auth import RegisterRequest, LoginRequest, SocialLoginRequest, RefreshRequest, AuthResponse
from app.core.config import settings

router = APIRouter(prefix="/auth", tags=["Auth"])


@router.post("/register", response_model=AuthResponse, status_code=201)
async def register(body: RegisterRequest, db: AsyncSession = Depends(get_db)):
    result = await db.execute(select(User).where(User.email == body.email))
    if result.scalar_one_or_none():
        raise HTTPException(409, detail={"error": "email_exists", "message": "이미 존재하는 이메일입니다."})

    user = User(email=body.email, hashed_password=hash_password(body.password), name=body.name)
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

    if settings.GOOGLE_CLIENT_ID and token_data.get("aud") != settings.GOOGLE_CLIENT_ID:
        raise HTTPException(401, detail={"error": "invalid_token", "message": "토큰의 대상 앱이 올바르지 않습니다."})

    google_sub = token_data.get("sub")
    email = token_data.get("email")

    if not google_sub or not email:
        raise HTTPException(401, detail={"error": "invalid_token", "message": "Google 계정 정보를 가져올 수 없습니다."})

    name = token_data.get("name") or email.split("@")[0]

    result = await db.execute(select(User).where(User.provider == "google", User.provider_id == google_sub))
    user = result.scalar_one_or_none()

    if not user:
        email_result = await db.execute(select(User).where(User.email == email))
        user = email_result.scalar_one_or_none()

    if user:
        if user.provider == "email":
            user.provider = "google"
            user.provider_id = google_sub
            await db.commit()
            await db.refresh(user)
    else:
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


@router.post("/refresh")
async def refresh_token(body: RefreshRequest, db: AsyncSession = Depends(get_db)):
    try:
        user_id = decode_token(body.refresh_token)
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
