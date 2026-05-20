"""강의계획서 파싱 프롬프트 최적화용 드라이런 스크립트.

사용법:
    python scripts/parse_syllabus_dryrun.py path/to/syllabus.pdf \\
        --year 2026 --term 1

또는 평문 텍스트 직접 입력:
    python scripts/parse_syllabus_dryrun.py path/to/syllabus.txt --text \\
        --year 2026 --term 1

결과: 파싱된 JSON + 토큰 사용량을 stdout에 출력.
프롬프트를 수정하면서 동일 입력에 대한 출력 품질을 반복 검증한다.
"""

from __future__ import annotations

import argparse
import asyncio
import json
import sys
from pathlib import Path

from app.services.pdf_text import extract_text_from_pdf_path
from app.services.syllabus_parser import SyllabusParseError, parse_syllabus


async def _run(file_path: Path, is_text: bool, year: int, term: str) -> int:
    if is_text:
        text = file_path.read_text(encoding="utf-8")
    else:
        text = extract_text_from_pdf_path(str(file_path))

    print(f"[input] {len(text)} chars from {file_path}", file=sys.stderr)

    try:
        result = await parse_syllabus(text=text, year=year, term=term)
    except SyllabusParseError as exc:
        print(f"[error] {exc}", file=sys.stderr)
        return 1

    print(json.dumps(result.syllabus.model_dump(mode="json"), ensure_ascii=False, indent=2))
    print(
        f"\n[usage] model={result.usage.model} "
        f"prompt={result.usage.prompt_tokens} "
        f"completion={result.usage.completion_tokens} "
        f"total={result.usage.total_tokens}",
        file=sys.stderr,
    )
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description="Syllabus parser dry-run")
    parser.add_argument("path", type=Path, help="PDF or text file path")
    parser.add_argument("--text", action="store_true", help="treat input as plain text")
    parser.add_argument("--year", type=int, required=True)
    parser.add_argument("--term", choices=["1", "2", "summer", "winter"], required=True)
    args = parser.parse_args()

    return asyncio.run(_run(args.path, args.text, args.year, args.term))


if __name__ == "__main__":
    raise SystemExit(main())
