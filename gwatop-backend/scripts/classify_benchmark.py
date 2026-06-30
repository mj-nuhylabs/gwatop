"""분류·매칭·변경탐지 파이프라인 샘플 실행 + 지연시간/호출수 측정 (Stage 4).

DB 없이 LLM 파이프라인의 핵심부(통합 분류 / 과목 매칭 LLM / 변경 탐지)를
실제 호출로 돌려보며, 파일 1건당 **지연시간**과 **LLM 호출 횟수**를 측정한다.
app.core.metrics 가 자동 계측한 값을 그대로 읽어 출력한다.

샘플: 미적분학 필기 1 + 미적분학 강의계획서 1 + 선형대수 강의계획서 1.

실행:
    OPENAI_API_KEY=sk-... python -m scripts.classify_benchmark
    # 또는
    OPENAI_API_KEY=sk-... python scripts/classify_benchmark.py

주의: 실제 OpenAI 호출이 일어나므로 API 키와 약간의 비용이 필요하다.
"""
from __future__ import annotations

import asyncio
import os
import sys

# config.Settings 가 요구하는 더미 env (실제 인프라 연결 안 함). OPENAI_API_KEY 는 보존.
os.environ.setdefault("SECRET_KEY", "bench")
os.environ.setdefault("DATABASE_URL", "postgresql+asyncpg://t:t@localhost/t")
os.environ.setdefault("REDIS_URL", "redis://localhost:6379/0")
os.environ.setdefault("AWS_ACCESS_KEY_ID", "t")
os.environ.setdefault("AWS_SECRET_ACCESS_KEY", "t")
os.environ.setdefault("S3_BUCKET_NAME", "t")
# 벤치마크는 Redis 캐시 없이 매번 LLM 을 타도록(측정 일관성). 재실행 캐시 효과는 별도 데모.
os.environ.setdefault("CLASSIFY_CACHE_ENABLED", "false")

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from app.core import metrics  # noqa: E402
from app.services.change_detector import (  # noqa: E402
    ChangeContext,
    detect_changes,
    has_change_signal,
)
from app.services.course_matcher import match_course_llm  # noqa: E402
from app.services.doc_classifier import decide_document_kind  # noqa: E402


# ---------- 샘플 픽스처 ----------

SYLLABUS_CALC = """미적분학 (MATH 1011)  담당교수: 김민수   2025-2학기
강의실: 공학관 401   강의시간: 월 13:00-14:30, 수 13:00-14:30

[평가 방법]  중간고사 30% / 기말고사 40% / 과제 20% / 출석 10%
[운영 정책]  3회 이상 결석 시 F. 지각 2회는 결석 1회로 처리. 표절 시 0점.
[교재]  James Stewart, Calculus 8th edition

[주차별 일정]
1주차: 함수와 극한
2주차: 도함수의 정의
3주차: 미분법칙
4주차: 연쇄법칙   ※ 과제1 마감 4월 15일
5주차: 적분의 개념
6주차: 정적분과 부정적분
"""

SYLLABUS_LINEAR = """선형대수학 (MATH 2021)  담당교수: 이정현   2025-2학기
강의실: 자연관 215   강의시간: 화 10:00-11:30, 목 10:00-11:30

[성적 평가]  중간 35% · 기말 35% · 퀴즈 20% · 참여 10%
[수업 운영]  매주 퀴즈. 표절·대리출석 적발 시 F.
[참고문헌]  Gilbert Strang, Introduction to Linear Algebra

주차별 강의계획
1주차: 벡터와 행렬
2주차: 가우스 소거법
3주차: 행렬식
4주차: 벡터공간과 부분공간
5주차: 고유값과 고유벡터
"""

MATERIAL_CALC_NOTES = """미적분학 4주차 필기 정리

오늘 배운 내용: 연쇄법칙(chain rule)과 그 응용.
합성함수 f(g(x)) 의 도함수는 f'(g(x))·g'(x).
예제: d/dx sin(x^2) = cos(x^2)·2x.
테일러 급수로의 확장: 함수를 다항식으로 근사. 극한 개념 복습.
적분으로 넘어가기 전 미분 총정리.

※ 공지: 4주차 과제(과제1) 마감이 4월 15일에서 4월 22일로 연기되었습니다.
※ 공지: 이번 주 강의실이 공학관 401 에서 공학관 302 로 변경됩니다.
"""


class _FakeCourse:
    """match_course_llm 은 .name / .professor 만 읽으므로 경량 shim 으로 충분."""

    def __init__(self, name: str, professor: str | None = None):
        self.name = name
        self.professor = professor


def _fmt_metrics(m: metrics.PipelineMetrics) -> str:
    calls = " + ".join(
        f"{c.kind}/{c.model}{'*' if c.escalated else ''}" for c in m.calls
    ) or "(LLM 0회)"
    return (
        f"  ⏱  {m.elapsed_ms:7.0f} ms | LLM {m.llm_count}회, 임베딩 {m.embed_count}회, "
        f"승급 {m.escalation_count}회, 토큰 {m.total_tokens}\n"
        f"     호출: {calls}"
    )


async def _classify_sample(label: str, filename: str, text: str):
    m = metrics.start_pipeline(label)
    decision = await decide_document_kind(text, filename)
    print(f"\n■ {label}  ({filename})")
    print(
        f"  → doc_type={decision.doc_type}  confidence={decision.confidence:.2f}  "
        f"model={decision.used_model}  escalated={decision.escalated}  "
        f"needs_review={decision.needs_review}"
    )
    if decision.signals.course_name_guess:
        print(
            f"     과목추정={decision.signals.course_name_guess!r} "
            f"교수={decision.signals.professor!r} "
            f"keywords={decision.signals.subject_keywords}"
        )
    print(_fmt_metrics(m))
    return decision


async def main():
    if not os.environ.get("OPENAI_API_KEY"):
        print("ERROR: OPENAI_API_KEY 환경변수가 필요합니다.")
        sys.exit(1)

    print("=" * 72)
    print(" GwaTop 분류/매칭/변경탐지 벤치마크 (실제 LLM 호출)")
    print("=" * 72)

    elapsed_all: list[float] = []
    llm_all: list[int] = []

    # ----- 1) 통합 분류 (3개 샘플) -----
    print("\n[1] 추출신호+분류 1회 통합 (빠른모델→저신뢰시 승급)")
    samples = [
        ("미적분학 강의계획서", "calculus_syllabus.pdf", SYLLABUS_CALC),
        ("선형대수 강의계획서", "linear_algebra_syllabus.pdf", SYLLABUS_LINEAR),
        ("미적분학 필기", "calc_week4_notes.pdf", MATERIAL_CALC_NOTES),
    ]
    material_decision = None
    for label, fname, text in samples:
        d = await _classify_sample(label, fname, text)
        cur = metrics.current()
        elapsed_all.append(cur.elapsed_ms)
        llm_all.append(cur.llm_count)
        if d.kind == "material":
            material_decision = d

    # ----- 2) 과목 매칭 (학습자료 → 올바른 강의계획서). 모호할 때 LLM. -----
    print("\n[2] 과목 매칭 LLM 디스앰비규에이션 (subject_keywords 활용)")
    m = metrics.start_pipeline("course_match")
    candidates = [_FakeCourse("미적분학", "김민수"), _FakeCourse("선형대수학", "이정현")]
    kws = (material_decision.signals.subject_keywords if material_decision else []) or [
        "연쇄법칙", "적분", "극한", "테일러급수",
    ]
    idx, conf, reason = await match_course_llm(
        "미적분", None, "2025-2학기", kws, candidates,
    )
    chosen = candidates[idx].name if idx is not None else "(매칭 없음 → 신규 생성)"
    print(f"\n■ '미적분' + keywords={kws}")
    print(f"  → 매칭: {chosen}  confidence={conf:.2f}")
    print(f"     reason: {reason}")
    print(_fmt_metrics(m))
    elapsed_all.append(m.elapsed_ms)
    llm_all.append(m.llm_count)

    # ----- 3) 변경 탐지 (키워드 게이트 → LLM) -----
    print("\n[3] 변경 탐지 (키워드 게이트 통과 후에만 LLM)")
    gate = has_change_signal(MATERIAL_CALC_NOTES)
    print(f"\n■ 키워드 게이트: {'통과(변경 표현 있음)' if gate else '차단(LLM 생략)'}")
    if gate:
        m = metrics.start_pipeline("change_detect")
        ctx = ChangeContext(
            class_time="월 13:00-14:30, 수 13:00-14:30",
            location="공학관 401",
            assignments=[("과제1", "2025-04-15 23:59")],
        )
        updates = await detect_changes(MATERIAL_CALC_NOTES, ctx)
        print(f"  → 변경 후보 {len(updates)}건 (자동 반영 안 함 — 사용자 승인 대상)")
        for u in updates:
            print(
                f"     · [{u.field}] {u.old_value!r} → {u.new_value!r}  "
                f"(conf={u.confidence:.2f}) 근거: {u.evidence!r}"
            )
        print(_fmt_metrics(m))
        elapsed_all.append(m.elapsed_ms)
        llm_all.append(m.llm_count)

    # ----- 요약 + 개선 전/후 비교 -----
    n = len(elapsed_all)
    print("\n" + "=" * 72)
    print(" 요약")
    print("=" * 72)
    print(f"  측정 단계 수: {n}")
    print(f"  평균 지연시간: {sum(elapsed_all)/n:.0f} ms")
    print(f"  평균 LLM 호출: {sum(llm_all)/n:.2f} 회")
    print("\n  [개선 전/후 (구조적 비교)]")
    print("   - 분류(material): 이전 doc_type LLM(1) + 과목명 LLM(1) = 최대 2회")
    print("                     이후 통합 1회(빠른모델, 저신뢰시만 승급) + 캐시 적중 시 0회")
    print("   - 변경 탐지: 이전 기능 없음 → 이후 키워드 게이트 통과 시에만 1회")
    print("   - 입력: 분류는 앞부분 일부만(CLASSIFY_DOC_INPUT_CHARS) 전송 → 입력 토큰↓")
    print("   - 배치: 파일별 분류 병렬화(BATCH_INGEST_CONCURRENCY)")


if __name__ == "__main__":
    asyncio.run(main())
