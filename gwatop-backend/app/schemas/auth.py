from pydantic import BaseModel, EmailStr
import uuid


class RegisterRequest(BaseModel):
    email: EmailStr
    password: str
    name: str


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
