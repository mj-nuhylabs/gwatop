"""structured_llm.build_strict_schema 의 OpenAI strict json_schema 변환 검증.

OpenAI 실 호출 없이도 검증 가능한 핵심 불변식:
  1. 모든 object 노드에 additionalProperties=false
  2. 모든 object 노드의 required = properties 의 전체 키 (strict 필수 조건)
  3. strict 미지원 제약 키워드(minimum/maximum/maxLength/default/title) 제거
  4. properties / $defs 의 "이름" 키는 보존 (실수로 스킵하면 스키마가 붕괴)
  5. 재귀 모델($ref/$defs 자기참조) 보존
"""

from __future__ import annotations

from typing import Literal

from pydantic import BaseModel, Field

from app.services.content_generators import (
    _FlashcardResponse, _Mindmap, _MemorizeResponse, _QuizResponse, _TopicsResponse,
)
from app.services.structured_llm import build_strict_schema


def _walk_objects(node):
    """스키마 트리에서 type=object 노드를 모두 순회 (properties/$defs/items/anyOf 재귀)."""
    if isinstance(node, dict):
        if node.get("type") == "object":
            yield node
        for key in ("properties", "$defs"):
            for sub in (node.get(key) or {}).values():
                yield from _walk_objects(sub)
        if "items" in node:
            yield from _walk_objects(node["items"])
        for sub in node.get("anyOf", []):
            yield from _walk_objects(sub)
    elif isinstance(node, list):
        for item in node:
            yield from _walk_objects(item)


_FORBIDDEN_KEYS = {
    "minimum", "maximum", "exclusiveMinimum", "exclusiveMaximum",
    "minLength", "maxLength", "minItems", "maxItems",
    "pattern", "format", "default", "title", "multipleOf",
}


def _all_keys(node):
    if isinstance(node, dict):
        for k, v in node.items():
            yield k
            # properties/$defs 의 '이름' 키는 스키마 키워드가 아니므로 값만 검사.
            if k in ("properties", "$defs"):
                for sub in v.values():
                    yield from _all_keys(sub)
            else:
                yield from _all_keys(v)
    elif isinstance(node, list):
        for item in node:
            yield from _all_keys(item)


def _assert_strict(schema: dict) -> None:
    objs = list(_walk_objects(schema))
    assert objs, "최소 한 개의 object 노드가 있어야 한다"
    for obj in objs:
        props = obj.get("properties") or {}
        assert obj.get("additionalProperties") is False, "object 에 additionalProperties=false 필요"
        assert set(obj.get("required", [])) == set(props.keys()), (
            "required 는 properties 의 전체 키여야 한다"
        )
    # 미지원 키워드 제거 확인 (properties/$defs 이름 키는 제외).
    leaked = _FORBIDDEN_KEYS & set(_all_keys(schema))
    assert not leaked, f"strict 미지원 키워드가 남음: {leaked}"


def test_quiz_schema_is_strict():
    _assert_strict(build_strict_schema(_QuizResponse))


def test_flashcard_schema_is_strict():
    _assert_strict(build_strict_schema(_FlashcardResponse))


def test_memorize_schema_strips_int_bounds():
    # _MemPoint.importance 는 ge=1, le=5 → minimum/maximum 가 제거돼야 한다.
    schema = build_strict_schema(_MemorizeResponse)
    _assert_strict(schema)


def test_topics_schema_is_strict():
    _assert_strict(build_strict_schema(_TopicsResponse))


def test_mindmap_recursive_schema_preserved():
    schema = build_strict_schema(_Mindmap)
    _assert_strict(schema)
    # 재귀 자기참조($defs + $ref)가 살아 있어야 한다.
    assert "$defs" in schema, "재귀 마인드맵은 $defs 를 가져야 한다"
    serialized = repr(schema)
    assert "$ref" in serialized, "자기참조 $ref 가 보존돼야 한다"


def test_optional_field_becomes_nullable_not_dropped():
    # hint: str | None → anyOf[string, null] 형태로 보존되고 required 에 포함돼야 한다.
    schema = build_strict_schema(_FlashcardResponse)
    card = schema["$defs"]["_FlashCard"] if "$defs" in schema else None
    assert card is not None, "_FlashCard 가 $defs 에 있어야 한다"
    assert "hint" in card["required"], "nullable 필드도 strict 에선 required 여야 한다"


def test_syllabus_schema_strips_date_time_format():
    # ParsedSyllabus 는 date/time 타입(format: date/time)을 포함 — strict 에서 제거돼야 한다.
    from app.schemas.syllabus import ParsedSyllabus

    schema = build_strict_schema(ParsedSyllabus)
    _assert_strict(schema)
    # 중첩(course/class_times/exams/assignments)까지 모두 strict 규격이어야 한다.
    assert "$defs" in schema
    # Weekday Literal → enum 보존.
    assert "enum" in repr(schema), "Weekday Literal → enum 보존돼야 한다"


def test_constraint_keywords_stripped_on_synthetic_model():
    """min/max/pattern/length 가 골고루 있는 합성 모델로 제거 로직을 직접 검증."""

    class _Inner(BaseModel):
        code: str = Field(..., pattern=r"^[A-Z]+$", max_length=10)
        score: int = Field(0, ge=0, le=100)

    class _Outer(BaseModel):
        name: str = Field(..., min_length=1, max_length=50)
        count: int = Field(0, ge=0)
        tags: list[str] = Field(default_factory=list)
        kind: Literal["a", "b"] = "a"
        inner: _Inner

    schema = build_strict_schema(_Outer)
    _assert_strict(schema)
    # enum 은 보존돼야 한다.
    assert "enum" in repr(schema), "Literal → enum 은 보존돼야 한다"
