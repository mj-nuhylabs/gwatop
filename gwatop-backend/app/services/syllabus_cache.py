"""강의계획서 파싱 결과 Redis 캐시.

같은 강의계획서(extracted_text)를 재파싱하지 않게 만든다.
- 동일 PDF 재업로드 (디버깅 중 흔함)
- 사용자가 같은 파일을 다른 과목에 다시 올리는 케이스
- 재시도 후 같은 결과 도달

캐시 키는 (cleaned_text + year + term) 의 SHA256. 학기 컨텍스트가 바뀌면
절대 날짜 매핑이 달라지므로 캐시 키에 포함한다.

Redis 가용성에 의존하지 않는다 — 연결 실패 시 silent miss 처리.
"""

from __future__ import annotations

import hashlib
import json
import logging
from typing import Any

from app.core.config import settings
from app.schemas.syllabus import SyllabusParseResult

logger = logging.getLogger(__name__)

# 7일. 학기 중 같은 강의계획서가 재파싱될 일은 거의 없으므로 길게 잡아도 무방.
_CACHE_TTL_SECONDS = 7 * 24 * 60 * 60
_CACHE_PREFIX = "syllabus:parsed:v1:"

# redis 클라이언트는 lazy init — 모듈 import 시 연결 실패하면 워커 자체가 죽는 걸 방지.
_redis_client: Any | None = None
_redis_unavailable = False


def _get_redis():
    """redis.asyncio 클라이언트를 lazy init. 사용 불가능하면 None을 반환한다.

    celery[redis] 의존성이 redis 패키지를 가져오므로 import 자체는 안전하지만,
    Redis 서버가 죽었거나 URL이 잘못된 환경에서 캐싱 전체가 막히지 않게 None fallback.
    """
    global _redis_client, _redis_unavailable
    if _redis_unavailable:
        return None
    if _redis_client is not None:
        return _redis_client
    try:
        from redis import asyncio as aioredis  # type: ignore[import-not-found]
        _redis_client = aioredis.from_url(
            settings.REDIS_URL,
            encoding="utf-8",
            decode_responses=True,
            socket_connect_timeout=2,
            socket_timeout=2,
        )
        return _redis_client
    except Exception as exc:
        logger.warning("syllabus_cache: redis client init failed (%s) — cache disabled", exc)
        _redis_unavailable = True
        return None


def make_cache_key(text: str, year: int, term: str) -> str:
    """캐시 키 생성. 텍스트 + 학기 컨텍스트 SHA256."""
    h = hashlib.sha256()
    h.update(f"{year}|{term}|".encode("utf-8"))
    h.update(text.encode("utf-8"))
    return _CACHE_PREFIX + h.hexdigest()


async def get_cached(cache_key: str) -> SyllabusParseResult | None:
    """캐시 hit 시 SyllabusParseResult 반환, miss 시 None."""
    client = _get_redis()
    if client is None:
        return None
    try:
        payload = await client.get(cache_key)
    except Exception as exc:
        logger.warning("syllabus_cache: GET failed (%s) — treating as miss", exc)
        return None
    if not payload:
        return None
    try:
        return SyllabusParseResult.model_validate(json.loads(payload))
    except Exception as exc:
        # 스키마가 바뀐 캐시 엔트리는 무시. 다음 파싱이 새 결과로 덮어쓴다.
        logger.warning("syllabus_cache: stale cache entry (%s) — ignoring", exc)
        return None


async def set_cached(cache_key: str, result: SyllabusParseResult) -> None:
    """파싱 결과를 캐시에 저장. 실패해도 silent."""
    client = _get_redis()
    if client is None:
        return
    try:
        payload = result.model_dump_json()
        await client.setex(cache_key, _CACHE_TTL_SECONDS, payload)
    except Exception as exc:
        logger.warning("syllabus_cache: SETEX failed (%s) — cache write skipped", exc)
