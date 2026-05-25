"""강의계획서 PDF의 표 추출 가능 여부 진단.

사용법:
    cd ~/gwatop/gwatop-backend
    python scripts/probe_syllabus_tables.py path/to/syllabus.pdf

출력:
    - 각 페이지에서 발견된 표 개수와 크기
    - 표 셀 첫 3행 미리보기
    - extract_tables_from_pdf() 의 ParsedWeek 결과 (성공 시) 또는 fallback 이유 (실패 시)

SYLLABUS_TABLE_EXTRACTION_ENABLED 를 true 로 켜기 전에 이걸로 사용자의 강의계획서 PDF
샘플 2-3개가 잘 잡히는지 확인하는 게 안전하다.
"""

from __future__ import annotations

import sys
from pathlib import Path

# scripts/ 디렉토리에서 직접 실행할 수 있도록 PYTHONPATH 보정
ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

import fitz  # noqa: E402

from app.services.pdf_text import extract_tables_from_pdf  # noqa: E402


def main(path: str) -> None:
    pdf_bytes = Path(path).read_bytes()
    print(f"=== {path} ({len(pdf_bytes)} bytes) ===\n")

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
        return

    print(f"→ {len(weeks)} weeks extracted:")
    for w in weeks:
        topic = (w.topic or "")[:40]
        notes = (w.notes or "").replace("\n", " ")[:60]
        print(f"  week {w.week_number:>2}: topic={topic!r:42} notes={notes!r}")


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("usage: python scripts/probe_syllabus_tables.py <path-to-pdf>")
        sys.exit(1)
    main(sys.argv[1])
