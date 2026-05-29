"""BUG-1 회귀 테스트 — decode_token 의 토큰 타입 강제.

refresh 토큰(30일)이 access 토큰처럼 보호 API 인증(get_current_user)에 쓰이는
token confusion 을 막는다. 기존에 발급된(type 클레임 없는) access 토큰은
하위호환으로 access 경로에서 계속 통과해야 한다.
"""
from datetime import datetime, timedelta, timezone

import pytest
from jose import JWTError, jwt

from app.core.config import settings
from app.core.security import create_access_token, create_refresh_token, decode_token

USER_ID = "11111111-1111-1111-1111-111111111111"


def test_access_token_roundtrip():
    tok = create_access_token(USER_ID)
    assert decode_token(tok) == USER_ID  # 기본 expected_type="access"
    assert decode_token(tok, expected_type="access") == USER_ID


def test_refresh_token_accepted_on_refresh_path():
    tok = create_refresh_token(USER_ID)
    assert decode_token(tok, expected_type="refresh") == USER_ID


def test_refresh_token_rejected_as_access():
    """핵심: refresh 토큰을 access 경로에 쓰면 거부돼야 한다 (token confusion 방지)."""
    tok = create_refresh_token(USER_ID)
    with pytest.raises(JWTError):
        decode_token(tok)  # expected_type 기본값 "access"


def test_access_token_rejected_on_refresh_path():
    tok = create_access_token(USER_ID)
    with pytest.raises(JWTError):
        decode_token(tok, expected_type="refresh")


def test_legacy_token_without_type_treated_as_access():
    """type 클레임이 없는 기존 access 토큰은 하위호환으로 access 경로에서 통과."""
    legacy = jwt.encode(
        {"sub": USER_ID, "exp": datetime.now(timezone.utc) + timedelta(minutes=60)},
        settings.SECRET_KEY,
        settings.ALGORITHM,
    )
    assert decode_token(legacy) == USER_ID
    # 단, refresh 경로에는 통과하면 안 됨 (type 없음 → access 로 간주).
    with pytest.raises(JWTError):
        decode_token(legacy, expected_type="refresh")
