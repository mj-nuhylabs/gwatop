"""손글씨/스캔 PDF OCR fallback — PyMuPDF 가 빈 텍스트를 반환할 때 작동.

전략:
1. PyMuPDF 가 페이지에서 텍스트를 거의 못 뽑았다 (보통 손글씨 또는 이미지 PDF)
2. 각 페이지를 PNG 이미지로 렌더링 (PyMuPDF 의 pixmap 기능)
3. GPT-4o-mini 의 비전 입력으로 한 번에 한 페이지씩 보내 텍스트 추출
4. 페이지별 결과를 합쳐 반환

성능:
- 페이지 수가 많으면 asyncio.gather 로 병렬화 — N 페이지를 ~N/4 시간에 처리
- 4o-mini vision 은 페이지당 ~2~5초

비용:
- gpt-4o-mini vision 은 토큰 기반. 1024x1024 이미지 ≈ 1.4K 토큰 입력.
- 페이지당 약 $0.0001 ~ $0.0005 (대부분 출력 텍스트 양에 따라 결정)
- 50페이지 손글씨 노트 ≈ $0.01~$0.025
"""

from __future__ import annotations

import asyncio
import base64
import logging
from io import BytesIO

import fitz  # PyMuPDF
from openai import AsyncOpenAI, OpenAIError

from app.core.config import settings

logger = logging.getLogger(__name__)

MIN_TEXT_THRESHOLD = 300  # 추출 텍스트가 이 미만이면 OCR fallback 시도
MAX_PAGES_TO_OCR = 50      # 안전 상한 — 너무 큰 PDF 는 비용 폭발 방지
TARGET_DPI = 144           # 이미지 해상도. 손글씨는 너무 낮으면 인식 실패, 너무 높으면 토큰 ↑


class OCRError(Exception):
    pass


_client: AsyncOpenAI | None = None
_client_loop: asyncio.AbstractEventLoop | None = None


def _get_client() -> AsyncOpenAI:
    """현재 이벤트 루프에 바인딩된 AsyncOpenAI 클라이언트를 반환한다.

    Celery 는 태스크마다 새 asyncio.run() 루프를 만든다. AsyncOpenAI 내부 httpx/anyio
    상태는 생성 시점 루프에 묶이므로, 다른 루프에서 재사용하면 'Future attached to a
    different loop' 류 에러가 난다. 루프가 바뀌면 클라이언트를 새로 만든다(같은 태스크
    안에서는 캐시 재사용).
    """
    global _client, _client_loop
    if not settings.OPENAI_API_KEY:
        raise OCRError("OPENAI_API_KEY is not configured")
    try:
        loop = asyncio.get_running_loop()
    except RuntimeError:
        loop = None
    if _client is None or _client_loop is not loop:
        _client = AsyncOpenAI(
            api_key=settings.OPENAI_API_KEY,
            timeout=settings.OPENAI_REQUEST_TIMEOUT,
            max_retries=settings.OPENAI_MAX_RETRIES,
        )
        _client_loop = loop
    return _client


OCR_SYSTEM = """당신은 한국 대학생의 손글씨 학습 노트를 디지털 텍스트로 변환하는 OCR 어시스턴트입니다.

규칙:
1. 이미지에 보이는 모든 글자(한글·영문·수식·기호)를 순서대로 옮겨 적습니다.
2. 그림/도식은 [그림: 짧은 설명] 형태로 표기.
3. 표는 줄바꿈으로 구분된 평문으로 풀어쓰기.
4. 추측·의역 금지 — 글씨가 안 보이면 [?]로 표시.
5. 출력은 JSON 객체: {"text": "추출된 모든 텍스트", "confidence": 0.0~1.0}.
6. confidence: 글씨가 명확하면 0.9+, 부분적으로 흐리면 0.5~0.8, 거의 안 보이면 0.3 이하.
"""


def render_pdf_pages_to_png(
    pdf_bytes: bytes, *, max_pages: int = MAX_PAGES_TO_OCR, dpi: int = TARGET_DPI
) -> list[bytes]:
    """PDF 바이트를 받아 페이지별 PNG bytes 리스트 반환."""
    images: list[bytes] = []
    zoom = dpi / 72.0  # PyMuPDF 기본은 72 DPI
    matrix = fitz.Matrix(zoom, zoom)

    with fitz.open(stream=pdf_bytes, filetype="pdf") as doc:
        for i, page in enumerate(doc):
            if i >= max_pages:
                logger.warning("OCR: 페이지 수 상한(%d) 도달, 이후 페이지 무시", max_pages)
                break
            pix = page.get_pixmap(matrix=matrix, alpha=False)
            images.append(pix.tobytes("png"))
    return images


def _pdf_page_count(pdf_bytes: bytes) -> int:
    with fitz.open(stream=pdf_bytes, filetype="pdf") as doc:
        return doc.page_count


def _render_page_range(
    pdf_bytes: bytes, start: int, end: int, *, dpi: int = TARGET_DPI
) -> list[bytes]:
    """[start, end) 범위 페이지만 PNG bytes 로 렌더링 (배치 단위 OCR 용 — 메모리 절약)."""
    zoom = dpi / 72.0
    matrix = fitz.Matrix(zoom, zoom)
    out: list[bytes] = []
    with fitz.open(stream=pdf_bytes, filetype="pdf") as doc:
        for i in range(start, min(end, doc.page_count)):
            pix = doc[i].get_pixmap(matrix=matrix, alpha=False)
            out.append(pix.tobytes("png"))
    return out


def _detect_image_mime(data: bytes) -> str:
    """매직 바이트로 이미지 MIME 추정. GPT-4o-mini vision 이 받는 포맷으로 제한.

    PDF 페이지 렌더링은 항상 PNG 라 기본값이 image/png. 사용자가 직접 올린 이미지
    파일(JPEG/GIF/WEBP)도 정확한 MIME 를 붙여야 vision 입력이 거부되지 않는다.
    """
    if data[:3] == b"\xff\xd8\xff":
        return "image/jpeg"
    if data[:6] in (b"GIF87a", b"GIF89a"):
        return "image/gif"
    if data[:4] == b"RIFF" and data[8:12] == b"WEBP":
        return "image/webp"
    # PNG(\x89PNG) 및 그 외는 png 로 취급 — 대부분의 PDF 렌더 출력이 PNG.
    return "image/png"


async def _ocr_single_page(
    img_bytes: bytes, page_index: int, *,
    mime: str | None = None, detail: str | None = None,
) -> str:
    """한 이미지를 GPT-4o-mini vision 으로 OCR. 실패 시 빈 문자열.

    PDF 페이지(png)와 직접 업로드된 이미지 파일(jpg/png/...) 양쪽에서 재사용한다.
    mime 를 생략하면 매직 바이트로 자동 판별하고(JPEG/GIF/WEBP 업로드 대응),
    `detail="high"` 는 사진 OCR 정확도를 높인다(PDF 경로는 기본 None = 자동).
    """
    b64 = base64.b64encode(img_bytes).decode("ascii")
    if mime is None:
        mime = _detect_image_mime(img_bytes)
    image_url: dict = {"url": f"data:{mime};base64,{b64}"}
    if detail:
        image_url["detail"] = detail
    client = _get_client()
    try:
        response = await client.chat.completions.create(
            model="gpt-4o-mini",
            temperature=0.0,
            max_tokens=4000,
            response_format={"type": "json_object"},
            messages=[
                {"role": "system", "content": OCR_SYSTEM},
                {
                    "role": "user",
                    "content": [
                        {"type": "text", "text": f"이 이미지({page_index + 1})의 글씨를 모두 옮겨 적어주세요."},
                        {"type": "image_url", "image_url": image_url},
                    ],
                },
            ],
        )
    except OpenAIError as exc:
        logger.warning("OCR page %d failed: %s", page_index + 1, exc)
        return ""

    raw = response.choices[0].message.content or ""
    import json
    try:
        payload = json.loads(raw)
    except json.JSONDecodeError:
        # JSON 강제 모드라도 모델이 가끔 잘라먹음 — 그냥 raw 의 의미있는 부분만 추출 시도.
        return raw
    return str(payload.get("text") or "")


async def ocr_pdf(pdf_bytes: bytes) -> str:
    """PDF 전체를 OCR. 페이지별 결과를 \n\n 으로 join 해 반환.

    페이지들을 asyncio.gather 로 병렬 호출 — 50페이지 PDF 면 약 5~10초.
    OpenAI 호출 동시성 제한을 고려해 한 번에 최대 6개씩 처리.
    """
    total = _pdf_page_count(pdf_bytes)
    if total == 0:
        return ""
    n = min(total, MAX_PAGES_TO_OCR)
    if total > MAX_PAGES_TO_OCR:
        logger.warning("OCR: 페이지 수 상한(%d) 도달, 이후 페이지 무시", MAX_PAGES_TO_OCR)

    logger.info("OCR start: %d pages", n)

    # 배치 단위로 렌더링 → OCR. 전 페이지 PNG 를 한꺼번에 메모리에 들지 않아 워커
    # 메모리 점유가 ~BATCH_SIZE 장 수준으로 유지된다. OpenAI rate limit 보호도 겸함.
    BATCH_SIZE = 6
    results: list[str] = [""] * n
    for batch_start in range(0, n, BATCH_SIZE):
        batch_end = min(batch_start + BATCH_SIZE, n)
        # 이 배치 페이지만 렌더링 — 이전 배치 PNG 는 GC 됨.
        batch_pngs = await asyncio.to_thread(
            _render_page_range, pdf_bytes, batch_start, batch_end
        )
        coros = [
            _ocr_single_page(png, batch_start + i) for i, png in enumerate(batch_pngs)
        ]
        batch_results = await asyncio.gather(*coros, return_exceptions=True)
        for i, r in enumerate(batch_results):
            if isinstance(r, Exception):
                logger.warning("OCR page %d exception: %s", batch_start + i + 1, r)
                results[batch_start + i] = ""
            else:
                results[batch_start + i] = r

    joined = "\n\n".join(t for t in results if t.strip())
    logger.info(
        "OCR done: total chars=%d (pages=%d)", len(joined), n
    )
    return joined


async def ocr_image(image_bytes: bytes) -> str:
    """업로드된 단일 이미지 파일(JPEG/PNG/GIF/WEBP)을 OCR 해 텍스트 반환.

    PDF 처럼 페이지 렌더링이 필요 없다 — bytes 를 바로 vision 입력으로 넣는다.
    실패하거나 글씨가 없으면 빈 문자열.
    """
    if not image_bytes:
        return ""
    text = await _ocr_single_page(image_bytes, 0)
    logger.info("OCR image done: chars=%d", len(text))
    return text.strip()


def needs_ocr(extracted_text: str | None) -> bool:
    """PyMuPDF 추출 결과가 OCR 가 필요한 수준인지 판단."""
    if extracted_text is None:
        return True
    return len(extracted_text.strip()) < MIN_TEXT_THRESHOLD


# ---------- 이미지 파일(png/jpg/...) 직접 OCR ----------

# vision 입력 이미지의 긴 변 상한(px). 넘으면 절반씩 축소 — 토큰/비용 절감(품질 영향 미미).
IMAGE_OCR_MAX_DIM = 2600


def _normalize_image_to_png(data: bytes) -> bytes | None:
    """임의의 이미지 바이트(png/jpg/jpeg/gif/webp/bmp/tiff)를 RGB PNG 로 정규화.

    PyMuPDF 로 열어 색공간을 RGB 로 맞추고, 너무 크면 축소한다. 열 수 없으면 None.
    """
    try:
        pix = fitz.Pixmap(data)
    except Exception as exc:  # noqa: BLE001
        logger.warning("이미지 열기 실패: %s", exc)
        return None
    try:
        # CMYK 등 → RGB (PNG 인코딩 + vision 호환).
        if pix.colorspace is not None and pix.colorspace.name not in ("DeviceRGB", "DeviceGray"):
            pix = fitz.Pixmap(fitz.csRGB, pix)
        # 알파 제거(불필요한 용량↓, OCR 엔 무의미).
        if pix.alpha:
            pix = fitz.Pixmap(pix, 0)
        guard = 0
        while max(pix.width, pix.height) > IMAGE_OCR_MAX_DIM and guard < 4:
            pix.shrink(1)  # 긴 변 절반
            guard += 1
        return pix.tobytes("png")
    except Exception as exc:  # noqa: BLE001
        logger.warning("이미지 정규화 실패: %s", exc)
        return None


async def ocr_image(image_bytes: bytes) -> str:
    """단일 이미지 파일(사진/스캔)을 vision OCR 해서 텍스트를 반환한다.

    강의자료/강의계획서를 사진으로 올린 경우의 텍스트 소스. 실패 시 OCRError.
    """
    png = await asyncio.to_thread(_normalize_image_to_png, image_bytes)
    if not png:
        raise OCRError("이미지를 읽을 수 없어요 (지원하지 않는 형식이거나 손상된 파일).")
    text = await _ocr_single_page(png, 0, mime="image/png", detail="high")
    logger.info("image OCR done: chars=%d", len(text or ""))
    return text or ""
