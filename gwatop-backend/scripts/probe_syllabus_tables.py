"""강의계획서 PDF의 표 추출 가능 여부 진단.

사용법:
    # (가장 편함) DB에서 최근 syllabus 자동으로 가져오기 — 인자 없이 실행
    python scripts/probe_syllabus_tables.py

    # 특정 file_id 로 진단
    python scripts/probe_syllabus_tables.py --file-id <uuid>

    # S3 key 로 직접 진단
    python scripts/probe_syllabus_tables.py --s3 syllabi/uuid.pdf

    # 로컬 PDF 경로로 진단
    python scripts/probe_syllabus_tables.py /tmp/sample.pdf

출력:
    - 페이지별 발견된 표 개수와 크기
    - 표 셀 첫 3행 미리보기
    - extract_tables_from_pdf() 의 ParsedWeek 결과 (성공 시) 또는 fallback 사유 (실패 시)

SYLLABUS_TABLE_EXTRACTION_ENABLED 를 true 로 켜기 전에 이걸로 사용자의 강의계획서 PDF
샘플 2-3개가 잘 잡히는지 확인하는 게 안전하다.
"""

from __future__ import annotations

import argparse
import asyncio
import sys
from pathlib import Path

# scripts/ 디렉토리에서 직접 실행할 수 있도록 PYTHONPATH 보정
ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

import fitz  # noqa: E402

from app.services.pdf_text import extract_tables_from_pdf  # noqa: E402


async def _fetch_recent_syllabus() -> tuple[str, bytes]:
    """DB에서 가장 최근 업로드된 syllabus 파일을 S3에서 받아 bytes 로 반환."""
    from sqlalchemy import text
    from app.core.database import engine
    from app.services import s3

    async with engine.connect() as conn:
        row = (
            await conn.execute(
                text(
                    """
                    SELECT id, filename, s3_key
                    FROM files
                    WHERE is_syllabus = true AND s3_key IS NOT NULL
                    ORDER BY created_at DESC
                    LIMIT 1
                    """
                )
            )
        ).first()
    if row is None:
        raise SystemExit(
            "최근 업로드된 syllabus 파일이 DB에 없습니다. "
            "iOS에서 강의계획서를 한 번 업로드한 뒤 다시 실행해주세요."
        )
    file_id, filename, s3_key = row
    print(f"DB 최근 syllabus 사용: {filename} (file_id={file_id}, s3_key={s3_key})")
    pdf_bytes = await asyncio.to_thread(s3.download_to_bytes, s3_key)
    return f"{filename} (s3:{s3_key})", pdf_bytes


async def _fetch_by_file_id(file_id: str) -> tuple[str, bytes]:
    """file_id 로 DB 조회 후 S3 다운로드."""
    from sqlalchemy import text
    from app.core.database import engine
    from app.services import s3

    async with engine.connect() as conn:
        row = (
            await conn.execute(
                text("SELECT filename, s3_key FROM files WHERE id = :fid"),
                {"fid": file_id},
            )
        ).first()
    if row is None:
        raise SystemExit(f"file_id={file_id} 인 파일이 DB에 없습니다.")
    filename, s3_key = row
    if not s3_key:
        raise SystemExit(f"file_id={file_id} 의 s3_key 가 비어 있습니다.")
    print(f"file_id={file_id} → {filename} (s3_key={s3_key})")
    pdf_bytes = await asyncio.to_thread(s3.download_to_bytes, s3_key)
    return f"{filename} (s3:{s3_key})", pdf_bytes


def _fetch_by_s3_key(s3_key: str) -> tuple[str, bytes]:
    from app.services import s3

    pdf_bytes = s3.download_to_bytes(s3_key)
    return f"s3:{s3_key}", pdf_bytes


def _fetch_local(path: str) -> tuple[str, bytes]:
    return path, Path(path).read_bytes()


def run_probe(label: str, pdf_bytes: bytes) -> None:
    print(f"\n=== {label} ({len(pdf_bytes)} bytes) ===\n")

    # 1. 페이지별 raw 표 정보
    with fitz.open(stream=pdf_bytes, filetype="pdf") as doc:
        for p_idx, page in enumerate(doc):
            try:
                tabs = page.find_tables()
                table_list = getattr(tabs, "tables", None) or list(tabs)
            except Exception as exc:
                print(f"page {p_idx + 1}: find_tables() failed — {exc}")
                continue

            if not table_list:
                print(f"page {p_idx + 1}: no tables")
                continue

            print(f"page {p_idx + 1}: {len(table_list)} table(s)")
            for t_idx, tab in enumerate(table_list):
                try:
                    rows = tab.extract()
                except Exception as exc:
                    print(f"  table[{t_idx}] extract failed — {exc}")
                    continue
                if not rows:
                    print(f"  table[{t_idx}] empty")
                    continue
                print(f"  table[{t_idx}] {len(rows)} rows x {len(rows[0])} cols")
                for r_idx, row in enumerate(rows[:3]):
                    cells = [(c or "").strip()[:24] for c in row]
                    print(f"    row[{r_idx}]: {cells}")
                if len(rows) > 3:
                    print(f"    ... ({len(rows) - 3} more rows)")
            print()

    # 2. extract_tables_from_pdf() 의 최종 판정
    print("=== extract_tables_from_pdf() result ===")
    weeks = extract_tables_from_pdf(pdf_bytes)
    if weeks is None:
        print("→ None (LLM fallback 사용 예정)")
        print("  → SYLLABUS_TABLE_EXTRACTION_ENABLED=true 켜도 이 PDF는 기존 경로로 처리됩니다.")
        return

    print(f"→ {len(weeks)} weeks extracted:")
    for w in weeks:
        topic = (w.topic or "")[:40]
        notes = (w.notes or "").replace("\n", " ")[:60]
        print(f"  week {w.week_number:>2}: topic={topic!r:42} notes={notes!r}")
    print("\n  → 결과가 깔끔하면 .env 에 SYLLABUS_TABLE_EXTRACTION_ENABLED=true 추가 권장.")


async def amain(argv: list[str]) -> None:
    parser = argparse.ArgumentParser(
        description="강의계획서 PDF 표 추출 진단",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    parser.add_argument(
        "source",
        nargs="?",
        help="로컬 PDF 경로. 생략하면 DB 최근 syllabus 자동 사용.",
    )
    parser.add_argument("--file-id", help="files.id (UUID) 로 진단")
    parser.add_argument("--s3", help="S3 key 로 직접 다운로드 후 진단 (예: syllabi/xxx.pdf)")
    args = parser.parse_args(argv)

    if args.file_id:
        label, pdf_bytes = await _fetch_by_file_id(args.file_id)
    elif args.s3:
        label, pdf_bytes = _fetch_by_s3_key(args.s3)
    elif args.source:
        label, pdf_bytes = _fetch_local(args.source)
    else:
        label, pdf_bytes = await _fetch_recent_syllabus()

    run_probe(label, pdf_bytes)


if __name__ == "__main__":
    asyncio.run(amain(sys.argv[1:]))
