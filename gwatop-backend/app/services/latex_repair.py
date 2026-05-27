"""LLM 이 JSON 응답에서 LaTeX 백슬래시 이스케이프를 빼먹어서 망가진 문자열을 복구.

배경:
    GPT 가 JSON 안에 LaTeX 명령을 넣을 때 `\\\\text` (실제 JSON 두 백슬래시) 로 써야
    json.loads 후 `\\text` 로 풀린다. 모델이 가끔 `\\text` (JSON 한 백슬래시) 만 쓰면
    json.loads 가 `\\t` 를 TAB 으로 해석해 `<TAB>ext` 가 되어 화면에서 깨져 보인다.

    같은 메커니즘:
        `\\text`  → TAB(0x09) + "ext"      → \\text, \\times, \\theta, \\tau, \\tilde, \\to, \\top, \\tan, \\triangle
        `\\frac`  → FF(0x0C)  + "rac"      → \\frac, \\forall, \\flat
        `\\beta`  → BS(0x08)  + "eta"      → \\beta, \\binom, \\big, \\boxed
        `\\n...`  → NL(0x0A)  + "..."      → \\nabla, \\neq, \\not, \\nu  (단, 줄바꿈과 모호)
        `\\r...`  → CR(0x0D)  + "..."      → \\rho, \\rightarrow, \\right (단, CR 도 자연 등장 가능)

    iOS 의 KaTeX 가 받아서 렌더링하려면 백슬래시가 살아 있어야 한다.

복구 정책:
    - TAB / FF / BS 는 학습 콘텐츠 텍스트에 자연스럽게 등장하지 않으므로 전부 백슬래시 이스케이프로 단순 치환.
    - NL / CR 은 자연스러운 줄바꿈이 흔하므로 손대지 않음. (해당 LaTeX 명령은 모델이 망가뜨릴 가능성이 상대적으로 낮음.)
"""

from __future__ import annotations

from typing import Any


def repair_latex_in_string(s: str) -> str:
    """단일 문자열에서 컨트롤 문자를 백슬래시 이스케이프로 복구."""
    if not s:
        return s
    return (
        s.replace("\t", "\\t")
        .replace("\f", "\\f")
        .replace("\x08", "\\b")
    )


def repair_latex_in_payload(value: Any) -> Any:
    """JSON 페이로드(dict/list/str/원시) 를 재귀 순회하며 모든 문자열 복구.

    원본을 변경하지 않고 새 컬렉션을 반환 (불필요하게 큰 사본은 만들지 않음 — 문자열이 바뀌어야 새 객체).
    """
    if isinstance(value, str):
        return repair_latex_in_string(value)
    if isinstance(value, list):
        return [repair_latex_in_payload(item) for item in value]
    if isinstance(value, dict):
        return {key: repair_latex_in_payload(val) for key, val in value.items()}
    return value
