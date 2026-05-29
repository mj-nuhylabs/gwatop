from pydantic import BaseModel, EmailStr, Field
import uuid


class RegisterRequest(BaseModel):
    email: EmailStr
    # 비밀번호 변경(PasswordChangeRequest.new_password) 정책과 동일하게 8자 이상 강제.
    password: str = Field(..., min_length=8, max_length=200)
    name: str
    school: str | None = None
    student_id: str | None = None
    referral_code: str | None = None


class LoginRequest(BaseModel):
    email: EmailStr
    password: str


class SocialLoginRequest(BaseModel):
    provider: str  # google
    id_token: str


class RefreshRequest(BaseModel):
    refresh_token: str


class UserOut(BaseModel):
    id: uuid.UUID
    email: str
    name: str

    class Config:
        from_attributes = True


class AuthResponse(BaseModel):
    access_token: str
    refresh_token: str
    expires_in: int
    user: UserOut
