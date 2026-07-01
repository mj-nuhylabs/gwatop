"""파일명 + 임베딩을 결합해 강의 자료의 주차를 결정한다.

규칙:
  1) 파일명 regex로 주차를 추정 → confidence가 임계치 이상이면 즉시 채택.
  2) 그렇지 않으면 임베딩 코사인 유사도로 가장 가까운 주차를 고름.
  3) 두 방법 모두 실패하면 unclassified.

이 모듈은 순수 결정 로직만 담당한다 — DB I/O는 Celery 태스크에서 처리한다.
"""

from __future__ import annotations

import logging
from dataclasses import dataclass
from typing import Sequence

from app.core.config import settings
from app.services.embedding_classifier import (
    EmbeddingClassification,
    WeekEmbedding,
    classify_by_embedding,
)
from app.services.filename_classifier import (
    FilenameClassification,
    classify_by_filename,
)

logger = logging.getLogger(__name__)


@dataclass(frozen=True)
class ClassificationResult:
    week_number: int | None
    confidence: float
    # "filename" | "embedding" | "unclassified"
    source: str
    # 디버그/관측용 — UI 노출은 안 함.
    detail: dict


async def classify_file(
    *,
    filename: str,
    extracted_text: str | None,
    week_embeddings: Sequence[WeekEmbedding],
) -> ClassificationResult:
    """파일을 분류한다. 외부 호출 (Celery 태스크) 단일 진입점."""

    detail: dict = {}

    # --- 1) 파일명 regex ---
    fname_hit: FilenameClassification | None = classify_by_filename(filename)
    if fname_hit is not None:
        detail["filename"] = {
            "pattern": fname_hit.pattern,
            "matched": fname_hit.matched_text,
            "week": fname_hit.week_number,
            "confidence": fname_hit.confidence,
        }
        # 명시적 파일명 표기(주차/week/chapter/lecture)는 업로더의 직접 라벨이라 임베딩보다 신뢰한다.
        # 예: 'Ch 2'/'Ch 3' 슬라이드는 임베딩이 비슷해 같은 주차로 뭉치기 쉬우므로 파일명을 우선.
        # 약한 'prefix'("01_") 만 임베딩(2단계)에 양보하고 최후 fallback(3단계)으로 남긴다.
        explicit = fname_hit.pattern != "prefix"
        if explicit or fname_hit.confidence >= settings.CLASSIFY_FILENAME_CONFIDENCE:
            return ClassificationResult(
                week_number=fname_hit.week_number,
                confidence=fname_hit.confidence,
                source="filename",
                detail=detail,
            )

    # --- 2) 임베딩 유사도 ---
    embed_hit: EmbeddingClassification | None = None
    if extracted_text and week_embeddings:
        embed_hit = await classify_by_embedding(extracted_text, week_embeddings)
        if embed_hit is not None:
            detail["embedding"] = {
                "best_week": embed_hit.week_number,
                "best_similarity": embed_hit.similarity,
                "runner_up_week": embed_hit.runner_up_week,
                "runner_up_similarity": embed_hit.runner_up_similarity,
            }
            if embed_hit.similarity >= settings.CLASSIFY_EMBEDDING_FLOOR:
                return ClassificationResult(
                    week_number=embed_hit.week_number,
                    confidence=embed_hit.similarity,
                    source="embedding",
                    detail=detail,
                )

    # --- 3) 약한 파일명 fallback ---
    # 임베딩이 floor 미만일 때, 파일명에 약한 단서(예: prefix "01_")라도 있으면
    # 그 단서를 채택한다. 사용자가 직접 정정할 수 있도록 confidence는 낮게 유지.
    if fname_hit is not None:
        return ClassificationResult(
            week_number=fname_hit.week_number,
            confidence=fname_hit.confidence,
            source="filename",
            detail=detail,
        )

    return ClassificationResult(
        week_number=None,
        confidence=0.0,
        source="unclassified",
        detail=detail,
    )
