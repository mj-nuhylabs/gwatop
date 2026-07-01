"""모든 서비스가 공유하는, 이벤트 루프에 바인딩된 AsyncOpenAI 클라이언트.

Celery 는 태스크마다 새 asyncio.run() 루프를 만든다. AsyncOpenAI 내부 httpx/anyio
상태는 생성 시점 루프에 묶이므로, 다른 루프에서 재사용하면 'Future attached to a
different loop' 류 에러가 나고 연결 풀도 못 써 매 호출마다 TLS 재핸드셰이크가 든다.

루프가 바뀌면 클라이언트를 새로 만들고, 같은 루프(=같은 태스크) 안에서는 캐시를
재사용한다. 한 루프 안에선 모든 서비스(요약/분석/분류/임베딩/...)가 같은 클라이언트를
공유해 keep-alive 연결 풀을 함께 데운다 → 태스크 내 두 번째 OpenAI 호출부터 핸드셰이크 0.

(ocr_fallback 은 같은 패턴을 자체적으로 갖고 있어 그대로 둔다.)
"""

from __future__ import annotations

import asyncio

from openai import AsyncOpenAI

from app.core.config import settings

_client: AsyncOpenAI | None = None
_client_loop: asyncio.AbstractEventLoop | None = None


def get_async_openai() -> AsyncOpenAI:
    """현재 실행 중인 이벤트 루프에 바인딩된 공유 AsyncOpenAI 인스턴스를 반환한다.

    API 키 미설정 검사는 호출부(_get_client)에서 각자의 예외 타입으로 수행한다.
    """
    global _client, _client_loop
    try:
        loop = asyncio.get_running_loop()
    except RuntimeError:
        loop = None
    if _client is None or _client_loop is not loop:
        # timeout/max_retries 를 명시 — SDK 기본(600초)이면 네트워크 stall 시 한 호출이
        # 수 분간 매달려 배치 업로드가 통째로 지연된다. (근본 원인 수정)
        _client = AsyncOpenAI(
            api_key=settings.OPENAI_API_KEY,
            timeout=settings.OPENAI_REQUEST_TIMEOUT,
            max_retries=settings.OPENAI_MAX_RETRIES,
        )
        _client_loop = loop
    return _client
