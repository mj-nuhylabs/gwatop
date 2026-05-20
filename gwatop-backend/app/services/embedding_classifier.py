"""OpenAI 임베딩 + 코사인 유사도 기반 주차 분류기.

강의계획서의 주차별 topic/notes를 미리 임베딩해 둔 캐시(Course.weekly_topic_embeddings)와
업로드된 파일 텍스트의 임베딩을 비교하여 가장 가까운 주차를 고른다.

캐시 빌드는 ``build_weekly_topic_embeddings`` 에서 한 번에 수행하고,
실제 분류는 ``classify_by_embedding`` 에서 단 1회의 임베딩 호출로 끝난다.
"""

from __future__ import annotations

import logging
import math
from dataclasses import dataclass
from typing import Iterable, Sequence

from openai import AsyncOpenAI, OpenAIError

from app.core.config import settings
from app.schemas.syllabus import ParsedWeek

logger = logging.getLogger(__name__)


class EmbeddingClassifierError(Exception):
    pass


_client: AsyncOpenAI | None = None


def _get_client() -> AsyncOpenAI:
    global _client
    if _client is None:
        if not settings.OPENAI_API_KEY:
            raise EmbeddingClassifierError("OPENAI_API_KEY is not configured")
        _client = AsyncOpenAI(api_key=settings.OPENAI_API_KEY)
    return _client


@dataclass(frozen=True)
class WeekEmbedding:
    week_number: int
    vector: list[float]


@dataclass(frozen=True)
class EmbeddingClassification:
    week_number: int
    similarity: float  # 0.0 ~ 1.0
    runner_up_week: int | None
    runner_up_similarity: float


def _format_week_text(week: ParsedWeek) -> str:
    """주차 topic + notes 를 1줄로 합쳐 임베딩 입력으로 사용한다."""
    parts: list[str] = [f"Week {week.week_number}"]
    if week.topic:
        parts.append(week.topic.strip())
    if week.notes:
        parts.append(week.notes.strip())
    return " — ".join(parts)


async def _embed_texts(texts: Sequence[str]) -> list[list[float]]:
    if not texts:
        return []
    client = _get_client()
    try:
        response = await client.embeddings.create(
            model=settings.OPENAI_EMBEDDING_MODEL,
            input=list(texts),
        )
    except OpenAIError as exc:
        logger.exception("OpenAI embedding call failed")
        raise EmbeddingClassifierError(f"OpenAI embedding failed: {exc}") from exc

    return [item.embedding for item in response.data]


async def build_weekly_topic_embeddings(
    weeks: Iterable[ParsedWeek],
) -> list[WeekEmbedding]:
    """강의계획서 weeks를 임베딩해 Course.weekly_topic_embeddings 캐시 형태로 반환한다.

    빈 topic/notes 인 주차도 ``Week N`` 만으로 임베딩한다 — 임베딩 거리는 작아지지만
    week_number 그대로 보존되어야 후속 매칭에서 누락되지 않는다.
    """
    week_list = list(weeks)
    if not week_list:
        return []

    texts = [_format_week_text(w) for w in week_list]
    vectors = await _embed_texts(texts)
    return [
        WeekEmbedding(week_number=w.week_number, vector=v)
        for w, v in zip(week_list, vectors)
    ]


def serialize_week_embeddings(items: Iterable[WeekEmbedding]) -> list[dict]:
    return [{"week_number": it.week_number, "vector": it.vector} for it in items]


def deserialize_week_embeddings(data: Iterable[dict]) -> list[WeekEmbedding]:
    out: list[WeekEmbedding] = []
    for item in data:
        try:
            wn = int(item["week_number"])
            vec = [float(x) for x in item["vector"]]
        except (KeyError, TypeError, ValueError):
            continue
        out.append(WeekEmbedding(week_number=wn, vector=vec))
    return out


def _cosine(a: Sequence[float], b: Sequence[float]) -> float:
    if not a or not b or len(a) != len(b):
        return 0.0
    dot = 0.0
    na = 0.0
    nb = 0.0
    for x, y in zip(a, b):
        dot += x * y
        na += x * x
        nb += y * y
    if na <= 0 or nb <= 0:
        return 0.0
    return dot / (math.sqrt(na) * math.sqrt(nb))


async def classify_by_embedding(
    text: str,
    week_embeddings: Sequence[WeekEmbedding],
) -> EmbeddingClassification | None:
    """파일 텍스트를 임베딩해 캐시된 주차 벡터들과 비교한다.

    Args:
        text: 파일 본문 (extracted_text 의 일부).
        week_embeddings: Course.weekly_topic_embeddings 에서 deserialize한 캐시.

    Returns:
        매칭 실패(임베딩 호출 실패 또는 캐시가 비어있음) 시 None.
    """
    if not text.strip() or not week_embeddings:
        return None

    snippet = text.strip()[: settings.CLASSIFY_EMBEDDING_INPUT_CHARS]
    try:
        [vector] = await _embed_texts([snippet])
    except EmbeddingClassifierError:
        return None

    scored = sorted(
        (
            (we.week_number, _cosine(vector, we.vector))
            for we in week_embeddings
        ),
        key=lambda x: x[1],
        reverse=True,
    )
    if not scored:
        return None

    top_week, top_sim = scored[0]
    runner_week, runner_sim = (None, 0.0)
    if len(scored) > 1:
        runner_week, runner_sim = scored[1]

    return EmbeddingClassification(
        week_number=top_week,
        similarity=top_sim,
        runner_up_week=runner_week,
        runner_up_similarity=runner_sim,
    )
