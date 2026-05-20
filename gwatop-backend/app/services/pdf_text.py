"""PDF → 평문 텍스트 추출.

Day 3 오전(PyMuPDF 텍스트 추출 Celery 태스크)에서 사용할 헬퍼.
syllabus_parser.parse_syllabus(text=...) 의 입력으로 사용된다.
"""

from __future__ import annotations

import fitz  # PyMuPDF


def extract_text_from_pdf_bytes(data: bytes) -> str:
    with fitz.open(stream=data, filetype="pdf") as doc:
        return "\n\n".join(page.get_text("text") for page in doc)


def extract_text_from_pdf_path(path: str) -> str:
    with fitz.open(path) as doc:
        return "\n\n".join(page.get_text("text") for page in doc)
