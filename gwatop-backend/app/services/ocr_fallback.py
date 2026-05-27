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


def _get_client() -> AsyncOpenAI:
    global _client
    if _client is None:
        if not settings.OPENAI_API_KEY:
            raise OCRError("OPENAI_API_KEY is not configured")
        _client = AsyncOpenAI(api_key=settings.OPENAI_API_KEY)
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


async def _ocr_single_page(png_bytes: bytes, page_index: int) -> str:
    """한 페이지 이미지를 GPT-4o-mini vision 으로 OCR. 실패 시 빈 문자열."""
    b64 = base64.b64encode(png_bytes).decode("ascii")
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
                        {"type": "text", "text": f"이 페이지({page_index + 1}번)의 글씨를 모두 옮겨 적어주세요."},
                        {
                            "type": "image_url",
                            "image_url": {"url": f"data:image/png;base64,{b64}"},
                        },
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
    pages = render_pdf_pages_to_png(pdf_bytes)
    if not pages:
        return ""

    logger.info("OCR start: %d pages", len(pages))

    # OpenAI rate limit 보호를 위한 batch.
    BATCH_SIZE = 6
    results: list[str] = [""] * len(pages)
    for batch_start in range(0, len(pages), BATCH_SIZE):
        batch = pages[batch_start : batch_start + BATCH_SIZE]
        coros = [
            _ocr_single_page(png, batch_start + i) for i, png in enumerate(batch)
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
        "OCR done: total chars=%d (pages=%d)", len(joined), len(pages)
    )
    return joined


def needs_ocr(extracted_text: str | None) -> bool:
    """PyMuPDF 추출 결과가 OCR 가 필요한 수준인지 판단."""
    if extracted_text is None:
        return True
    return len(extracted_text.strip()) < MIN_TEXT_THRESHOLD
