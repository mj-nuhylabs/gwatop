"""유튜브 영상 링크 → 자막(transcript) 평문 추출.

`pdf_text` / `doc_text` 와 같은 역할: 추출 결과를 `File.extracted_text` 에 저장해
요약·AI 튜터·주차 분류에 그대로 쓴다.

⚠️ 운영 주의(검증됨 2026-06-29): EC2(클라우드 IP)에서 youtube-transcript-api 는
   **간헐적으로 RequestBlocked** 된다(연속/반복 요청 시 YouTube 가 IP 차단).
   → `_build_api()` 가 `settings.YOUTUBE_PROXY_URL` 이 있으면 프록시로 우회하도록
   설계해 두었다. 차단이 잦아지면 Webshare 등 프록시 URL 을 .env 에 넣기만 하면 된다.
   차단/자막없음/비공개 등은 모두 `YouTubeTranscriptUnavailable` 로 변환해
   사용자에게 명확한 한국어 메시지를 보여준다.
"""

from __future__ import annotations

import logging
import re
from urllib.parse import urlparse, parse_qs

import httpx

from app.core.config import settings

logger = logging.getLogger(__name__)


class YouTubeTranscriptUnavailable(Exception):
    """자막을 가져오지 못한 모든 경우(차단/자막없음/비공개/잘못된 URL)의 도메인 예외."""


# youtube.com/watch?v=ID, youtu.be/ID, /shorts/ID, /embed/ID, /live/ID 모두 커버.
_ID_RE = re.compile(r"^[A-Za-z0-9_-]{11}$")


def parse_video_id(url: str) -> str | None:
    """다양한 형태의 유튜브 URL 에서 11자 video id 를 뽑는다. 실패 시 None."""
    if not url:
        return None
    url = url.strip()
    # 순수 id 만 들어온 경우
    if _ID_RE.match(url):
        return url

    try:
        p = urlparse(url if "://" in url else f"https://{url}")
    except Exception:
        return None

    host = (p.hostname or "").lower().removeprefix("www.")

    if host == "youtu.be":
        cand = p.path.lstrip("/").split("/")[0]
        return cand if _ID_RE.match(cand) else None

    if host in ("youtube.com", "m.youtube.com", "music.youtube.com"):
        # /watch?v=ID
        if p.path == "/watch":
            v = parse_qs(p.query).get("v", [None])[0]
            return v if v and _ID_RE.match(v) else None
        # /shorts/ID, /embed/ID, /live/ID, /v/ID
        m = re.match(r"^/(?:shorts|embed|live|v)/([A-Za-z0-9_-]{11})", p.path)
        if m:
            return m.group(1)

    return None


def fetch_video_title(url: str) -> str | None:
    """oEmbed(키 불필요)로 영상 제목을 가져온다. 실패하면 None (호출자가 URL 로 대체)."""
    try:
        resp = httpx.get(
            "https://www.youtube.com/oembed",
            params={"url": url, "format": "json"},
            timeout=8.0,
        )
        if resp.status_code == 200:
            title = resp.json().get("title")
            if title and title.strip():
                return title.strip()[:300]
    except Exception:
        logger.info("youtube oembed title fetch 실패 url=%s", url, exc_info=True)
    return None


def _build_api():
    """YouTubeTranscriptApi 인스턴스 생성. 프록시 설정이 있으면 적용."""
    from youtube_transcript_api import YouTubeTranscriptApi
    from youtube_transcript_api.proxies import GenericProxyConfig

    proxy_url = getattr(settings, "YOUTUBE_PROXY_URL", "") or ""
    if proxy_url.strip():
        cfg = GenericProxyConfig(http_url=proxy_url, https_url=proxy_url)
        return YouTubeTranscriptApi(proxy_config=cfg)
    return YouTubeTranscriptApi()


# 자막 언어 우선순위 — 한국어 강의 우선, 없으면 영어, 그래도 없으면 사용 가능한 첫 자막.
_PREFERRED_LANGS = ["ko", "en"]


def fetch_transcript_for_url(url: str) -> str:
    """유튜브 URL → 자막 평문. 실패 시 YouTubeTranscriptUnavailable 발생."""
    video_id = parse_video_id(url)
    if not video_id:
        raise YouTubeTranscriptUnavailable(
            "유효한 유튜브 영상 링크가 아니에요. 영상 주소를 다시 확인해 주세요."
        )

    # 라이브러리 예외 타입 — 버전별 일부만 존재할 수 있어 방어적으로 import.
    from youtube_transcript_api import _errors as yt_errors

    api = _build_api()

    try:
        fetched = api.fetch(video_id, languages=_PREFERRED_LANGS)
    except getattr(yt_errors, "NoTranscriptFound", Exception):
        # 선호 언어 자막이 없으면 사용 가능한 아무 자막이나 시도.
        fetched = _fetch_any_available(api, video_id)
    except (
        getattr(yt_errors, "TranscriptsDisabled", ()),
        getattr(yt_errors, "VideoUnavailable", ()),
    ):
        raise YouTubeTranscriptUnavailable(
            "이 영상은 자막이 없어요. 자막(또는 자동 생성 자막)이 있는 영상만 학습할 수 있어요."
        )
    except Exception as exc:  # RequestBlocked / IpBlocked / 네트워크 등
        name = type(exc).__name__
        if "Block" in name or "TooManyRequests" in name:
            logger.warning("youtube transcript IP 차단 video=%s (%s)", video_id, name)
            raise YouTubeTranscriptUnavailable(
                "유튜브가 서버 요청을 일시적으로 제한했어요. 잠시 후 다시 시도해 주세요."
            )
        logger.exception("youtube transcript fetch 실패 video=%s", video_id)
        raise YouTubeTranscriptUnavailable(
            "자막을 가져오지 못했어요. 잠시 후 다시 시도해 주세요."
        )

    text = _join_snippets(fetched)
    if not text.strip():
        raise YouTubeTranscriptUnavailable(
            "이 영상의 자막이 비어 있어요. 다른 영상을 사용해 주세요."
        )
    return text


def _fetch_any_available(api, video_id: str):
    """선호 언어가 없을 때 사용 가능한 첫 자막을 가져온다."""
    try:
        transcript_list = api.list(video_id)
        for transcript in transcript_list:
            return transcript.fetch()
    except Exception:
        pass
    raise YouTubeTranscriptUnavailable(
        "이 영상은 자막이 없어요. 자막(또는 자동 생성 자막)이 있는 영상만 학습할 수 있어요."
    )


def _join_snippets(fetched) -> str:
    """FetchedTranscript(또는 list[dict]) → 줄바꿈으로 이어붙인 평문."""
    lines: list[str] = []
    for snip in fetched:
        # 1.x: snippet 객체(.text) / 구버전: dict("text")
        t = getattr(snip, "text", None)
        if t is None and isinstance(snip, dict):
            t = snip.get("text")
        if t and t.strip():
            lines.append(t.strip())
    return "\n".join(lines)
