"""Stage 1 통합 분류 — 빠른모델→큰모델 에스컬레이션 / needs_review 로직.

실제 LLM 은 호출하지 않는다. _call_model 을 monkeypatch 로 대체해 결정 로직만 검증한다.
asyncio.run 으로 돌려 pytest-asyncio 설정 없이도 실행되게 한다.
"""
import asyncio

from app.core.config import settings
from app.services import doc_classifier
from app.services.doc_classifier import DocSignals


def _sig(doc_type: str, conf: float, name: str = "미적분") -> DocSignals:
    return DocSignals(
        course_name_guess=name, course_code=None, professor=None, semester=None,
        has_grading_breakdown=False, has_weekly_schedule=False,
        has_course_policy=False, has_textbook_list=False,
        is_subject_content=True, subject_keywords=["적분"],
        doc_type=doc_type, confidence=conf, reason="t",
    )


def test_escalates_on_low_confidence(monkeypatch):
    monkeypatch.setattr(settings, "CLASSIFY_CACHE_ENABLED", False)
    calls: list[str] = []

    async def fake(model, filename, text):
        calls.append(model)
        # 빠른 모델은 저신뢰 → 큰 모델로 승급되어야 한다.
        return _sig("학습자료", 0.4) if model == settings.CLASSIFY_FAST_MODEL else _sig("학습자료", 0.95)

    monkeypatch.setattr(doc_classifier, "_call_model", fake)
    res = asyncio.run(doc_classifier.classify_document("본문", "f.pdf"))

    assert calls == [settings.CLASSIFY_FAST_MODEL, settings.CLASSIFY_ESCALATE_MODEL]
    assert res.escalated is True
    assert res.kind == "material"
    assert res.confidence == 0.95
    assert res.needs_review is False


def test_no_escalation_when_confident(monkeypatch):
    monkeypatch.setattr(settings, "CLASSIFY_CACHE_ENABLED", False)
    calls: list[str] = []

    async def fake(model, filename, text):
        calls.append(model)
        return _sig("강의계획서", 0.9)

    monkeypatch.setattr(doc_classifier, "_call_model", fake)
    res = asyncio.run(doc_classifier.classify_document("본문", "f.pdf"))

    assert calls == [settings.CLASSIFY_FAST_MODEL]  # 큰 모델 호출 없음
    assert res.kind == "syllabus"
    assert res.escalated is False


def test_needs_review_on_uncertain(monkeypatch):
    monkeypatch.setattr(settings, "CLASSIFY_CACHE_ENABLED", False)

    async def fake(model, filename, text):
        return _sig("불확실", 0.3)

    monkeypatch.setattr(doc_classifier, "_call_model", fake)
    res = asyncio.run(doc_classifier.classify_document("본문", "f.pdf"))

    assert res.needs_review is True
    # 불확실은 안전하게 material 로 흘리되 사용자 확인을 요청한다.
    assert res.kind == "material"


def test_both_models_fail_returns_review(monkeypatch):
    monkeypatch.setattr(settings, "CLASSIFY_CACHE_ENABLED", False)

    async def fake(model, filename, text):
        return None  # 파싱/호출 실패 시뮬레이션

    monkeypatch.setattr(doc_classifier, "_call_model", fake)
    res = asyncio.run(doc_classifier.classify_document("본문", "f.pdf"))

    assert res.needs_review is True
    assert res.doc_type == "불확실"
    assert res.confidence == 0.0
