"""파이프라인 계측 — 단계별 지연시간 + LLM/임베딩 호출 횟수 + 토큰.

개선 전/후 비교를 위한 baseline 을 만든다. 기존 코드 어디에도 레이턴시 계측이
없었기 때문에(토큰 카운트만 있었음) 이 모듈이 그 공백을 메운다.

설계
----
- contextvar 기반: 한 Celery 태스크(=하나의 asyncio.run 루프) 안에서 일어나는 모든
  LLM/임베딩 호출과 단계 타이밍을 한 곳에 모은다. 비동기 중첩 await 사이에서도
  같은 컨텍스트를 공유한다.
- 의존성 없음: 실패해도 파이프라인을 멈추지 않는다 (계측은 부가 기능).
- 호출부는 `start_pipeline()` → (작업) → `log_pipeline()` 만 하면 된다. 중간의
  `record_llm_call()` / `stage()` 는 서비스 계층이 자동으로 호출한다.

사용 예 (Celery 태스크 코루틴):
    m = start_pipeline("classify", file_id=file_id)
    async with stage("classify_file"):
        ...
    log_pipeline()   # [METRICS] file=... stage_ms={...} llm=N embed=M tokens=T elapsed_ms=...
"""

from __future__ import annotations

import contextvars
import json
import logging
import time
from contextlib import asynccontextmanager
from dataclasses import dataclass, field

logger = logging.getLogger("gwatop.metrics")


@dataclass
class LLMCall:
    kind: str       # "doc_classify" | "syllabus" | "summary" | "embedding" | ...
    model: str
    tokens: int
    ms: float
    escalated: bool = False  # 빠른모델→큰모델 승급으로 추가된 호출인지


@dataclass
class PipelineMetrics:
    label: str
    started_at: float = field(default_factory=time.perf_counter)
    extra: dict = field(default_factory=dict)
    calls: list[LLMCall] = field(default_factory=list)
    stages: dict[str, float] = field(default_factory=dict)  # name -> ms

    # --- 집계 ---
    @property
    def llm_count(self) -> int:
        return sum(1 for c in self.calls if c.kind != "embedding")

    @property
    def embed_count(self) -> int:
        return sum(1 for c in self.calls if c.kind == "embedding")

    @property
    def escalation_count(self) -> int:
        return sum(1 for c in self.calls if c.escalated)

    @property
    def total_tokens(self) -> int:
        return sum(c.tokens for c in self.calls)

    @property
    def elapsed_ms(self) -> float:
        return (time.perf_counter() - self.started_at) * 1000.0


# 현재 태스크의 메트릭. 없으면(=계측 시작 전 호출) record_* 는 조용히 무시된다.
_current: contextvars.ContextVar[PipelineMetrics | None] = contextvars.ContextVar(
    "pipeline_metrics", default=None
)


def start_pipeline(label: str, **extra) -> PipelineMetrics:
    """현재 컨텍스트에 새 메트릭을 바인딩하고 반환한다."""
    m = PipelineMetrics(label=label, extra=dict(extra))
    _current.set(m)
    return m


@asynccontextmanager
async def pipeline(label: str, **extra):
    """한 작업 단위의 메트릭을 측정하고 종료 시 자동으로 로그를 남긴다.

    토큰 reset 으로 **중첩 안전** — 배치가 파일별 파이프라인을 inline 으로 호출해도
    바깥 파이프라인이 복원된다. 예외가 나도 finally 에서 로그를 남긴다.
    """
    m = PipelineMetrics(label=label, extra=dict(extra))
    token = _current.set(m)
    try:
        yield m
    finally:
        try:
            log_pipeline(m)
        finally:
            _current.reset(token)


def current() -> PipelineMetrics | None:
    return _current.get()


def record_llm_call(
    kind: str, model: str, tokens: int, ms: float, *, escalated: bool = False
) -> None:
    """LLM(또는 임베딩) 호출 1건을 기록. 메트릭이 시작 안 됐으면 no-op."""
    m = _current.get()
    if m is None:
        return
    m.calls.append(
        LLMCall(kind=kind, model=model, tokens=int(tokens or 0), ms=ms, escalated=escalated)
    )


@asynccontextmanager
async def stage(name: str):
    """단계 실행 시간을 측정해 stages[name] 에 누적(ms)한다."""
    t0 = time.perf_counter()
    try:
        yield
    finally:
        m = _current.get()
        if m is not None:
            elapsed = (time.perf_counter() - t0) * 1000.0
            m.stages[name] = m.stages.get(name, 0.0) + elapsed


def log_pipeline(metrics: PipelineMetrics | None = None, **extra) -> None:
    """메트릭을 한 줄 구조화 로그로 출력한다.

    grep 하기 쉬운 `[METRICS]` 접두 — before/after 집계 스크립트가 이 라인을 파싱한다.
    """
    m = metrics or _current.get()
    if m is None:
        return
    payload = {
        "label": m.label,
        **m.extra,
        **extra,
        "elapsed_ms": round(m.elapsed_ms, 1),
        "llm_calls": m.llm_count,
        "embed_calls": m.embed_count,
        "escalations": m.escalation_count,
        "tokens": m.total_tokens,
        "stage_ms": {k: round(v, 1) for k, v in m.stages.items()},
        "by_call": [
            {"kind": c.kind, "model": c.model, "tokens": c.tokens, "ms": round(c.ms, 1),
             "escalated": c.escalated}
            for c in m.calls
        ],
    }
    logger.info("[METRICS] %s", json.dumps(payload, ensure_ascii=False))
