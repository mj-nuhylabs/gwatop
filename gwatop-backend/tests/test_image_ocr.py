"""이미지 파일(png/jpg/...) OCR 전처리 검증 (vision API 없이 가능한 부분).

배경: 강의자료/강의계획서를 '사진'으로 올려도 PDF 처럼 분류·파싱되도록, 업로드된
이미지를 vision OCR 에 넣기 전에 RGB PNG 로 정규화한다. 이 테스트는 정규화(열기/
색공간/축소/실패처리)와 업로드 허용 설정을 고정한다. 실제 OCR(모델 호출)은 제외.
"""

from __future__ import annotations

import fitz  # PyMuPDF

from app.core.config import settings
from app.services.ocr_fallback import IMAGE_OCR_MAX_DIM, _normalize_image_to_png


def _make_png(w: int, h: int) -> bytes:
    pix = fitz.Pixmap(fitz.csRGB, fitz.IRect(0, 0, w, h), False)
    pix.clear_with(255)  # 흰 배경
    return pix.tobytes("png")


def test_image_allowed_in_upload_policy():
    # 사진 업로드가 허용돼야 파이프라인에 진입한다.
    assert "image" in settings.allowed_file_types_set
    assert "pdf" in settings.allowed_file_types_set


def test_normalize_png_roundtrip():
    png = _make_png(200, 150)
    out = _normalize_image_to_png(png)
    assert out is not None
    # 결과는 다시 열리는 유효한 PNG.
    pix = fitz.Pixmap(out)
    assert (pix.width, pix.height) == (200, 150)


def test_normalize_jpg_input():
    # jpg 로 인코딩된 입력도 열려서 PNG 로 정규화돼야 한다 (사진 대부분 jpg).
    src = fitz.Pixmap(fitz.csRGB, fitz.IRect(0, 0, 120, 90), False)
    src.clear_with(200)
    jpg = src.tobytes("jpg")
    out = _normalize_image_to_png(jpg)
    assert out is not None
    assert fitz.Pixmap(out).width == 120


def test_normalize_downscales_large_image():
    # 긴 변이 상한을 크게 넘으면 절반씩 축소돼 상한 이하가 된다.
    big = _make_png(IMAGE_OCR_MAX_DIM * 2 + 500, 100)
    out = _normalize_image_to_png(big)
    assert out is not None
    pix = fitz.Pixmap(out)
    assert max(pix.width, pix.height) <= IMAGE_OCR_MAX_DIM


def test_normalize_invalid_bytes_returns_none():
    assert _normalize_image_to_png(b"this is not an image") is None
    assert _normalize_image_to_png(b"") is None
