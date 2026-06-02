"""AI 튜터 채팅 — 파일 컨텍스트 기반 멀티턴 응답 (텍스트 + 비전 + 사용자 노트).

설계 (2026-05-27 개편):
-----------------------------------------------------------------------------
사용자가 "공식이 잘리고 대충 알려주는 느낌"이라고 피드백을 줘서 다음을 동시 개편:

1. **프롬프트 구조**: GPT 베스트 프랙티스 (Anthropic/OpenAI 가이드 공통) 를 따라
   "ROLE → CONTEXT → GUIDELINES → OUTPUT FORMAT → FORBIDDEN → SELF-CHECK"
   6개 섹션으로 분리. 헤더는 `##` 마크다운으로 명시해 모델이 각 섹션의 책임을 인지.

2. **출력 강제**: 마크다운 인덱스(`## 1. ...`) + KaTeX 수식 + 굵게/리스트를
   응답 스키마 예시로 함께 제공 → few-shot 효과로 일관성↑.

3. **이미지 첨부**: OpenAI Chat Completions 의 multimodal content list 사용.
   `image_data_urls` 가 비어 있지 않으면 마지막 user 메시지를 content list 로 구성.

4. **사용자 노트 컨텍스트**: 파일 본문 외에 사용자가 적은 노트를 추가 컨텍스트로 주입.
   사용자가 "이 부분이 이해 안 갔어요" 라고 적었으면 그 부분 위주로 답변.

5. **max_tokens 900 → 2500**: 짧게 잘리는 문제 해결. settings.OPENAI_TUTOR_MAX_TOKENS.

6. **모델 분리**: settings.OPENAI_TUTOR_MODEL (기본 gpt-4o-mini, vision 지원).

7. **스트리밍**: `ask_tutor_stream` 추가 — SSE 로 토큰을 흘려보내 "AI 가 생각 중"
   체감 시간 단축. 기존 동기 호출 `ask_tutor` 는 fallback 으로 유지.
"""

from __future__ import annotations

import logging
from typing import AsyncIterator, Iterable

from openai import AsyncOpenAI, OpenAIError

from app.core.config import settings

logger = logging.getLogger(__name__)


MAX_CONTEXT_CHARS = 18000
MAX_HISTORY_TURNS = 8        # user/assistant 합쳐서 최근 N개 메시지만 컨텍스트로
MAX_NOTES_CHARS = 4000       # 사용자 노트 컨텍스트 상한 (너무 길면 토큰 낭비)
MAX_IMAGES_PER_TURN = 4      # 한 질문당 최대 첨부 이미지 수


class TutorError(Exception):
    pass


_client: AsyncOpenAI | None = None


def _get_client() -> AsyncOpenAI:
    global _client
    if _client is None:
        if not settings.OPENAI_API_KEY:
            raise TutorError("OPENAI_API_KEY is not configured")
        _client = AsyncOpenAI(api_key=settings.OPENAI_API_KEY)
    return _client


# ---------------------------------------------------------------------------
# 프롬프트
# ---------------------------------------------------------------------------

def _truncate_middle(text: str, limit: int) -> str:
    if len(text) <= limit:
        return text
    head = text[: limit - 500]
    tail = text[-500:]
    return f"{head}\n... [중략 — 길어서 일부 생략됨] ...\n{tail}"


def _format_notes(notes: list[tuple[str | None, str]] | None) -> str:
    """사용자가 작성한 노트들을 컨텍스트 블록으로 변환."""
    if not notes:
        return ""
    lines: list[str] = []
    used = 0
    for title, body in notes:
        head = f"### 노트: {title}\n" if title else "### 노트\n"
        block = head + body.strip() + "\n"
        if used + len(block) > MAX_NOTES_CHARS:
            lines.append("... [노트가 더 있지만 길이 제한으로 생략] ...\n")
            break
        lines.append(block)
        used += len(block)
    return "".join(lines)


def _build_system_prompt(
    *,
    file_text: str,
    filename: str | None,
    notes_block: str,
    has_images: bool,
) -> str:
    file_text = _truncate_middle(file_text, MAX_CONTEXT_CHARS)
    notes_block_full = (
        "\n## 사용자가 작성한 노트 (질문 의도 파악에 우선 참고)\n"
        f"{notes_block}\n"
        if notes_block.strip() else ""
    )
    image_note = (
        "- 사용자가 사진을 첨부했다면 그 사진의 수식·도형·필기를 자세히 읽고 답에 반영하세요.\n"
        "- 사진 속 수식은 LaTeX 로 재구성해서 보여주세요.\n"
        if has_images else ""
    )

    return f"""당신은 한국 대학생 전용 1:1 전문 학습 튜터 **"과탑 AI"** 입니다.
지금 학생이 보고 있는 강의 자료(`[자료 본문]`)와 학생이 작성한 노트를 토대로
질문에 답합니다. 단순 챗봇이 아니라 **실제 조교/튜터처럼** 깊이·구조·예시를
갖춰 응답하세요.

## 1. 역할 (Role)
- 한국어 사용. 단, 전문 용어(영어 약어/수식 명칭)는 그대로 표기.
- 학생이 시험을 잘 보고 개념을 정확히 이해하도록 돕는 것이 최우선 목표.
- 답을 **그냥 던지지 말고**, "왜 그런지" 까지 짧게라도 설명. (학습용)
- 모르는 건 모른다고 말하기 — 추측·환각 절대 금지.

## 2. 컨텍스트 (Context)
- 학생이 학습 중인 파일명: `{filename or '(미상)'}`
- 자료 본문, 학생 노트는 사용자 메시지 끝에 함께 제공됩니다.
- 사진이 있으면 그 사진이 학생의 질문 핵심입니다.

## 3. 답변 지침 (Guidelines)
1. **자료 우선**: 자료에 명시된 내용을 1순위로 인용·활용. 자료 밖 일반 지식은
   "(참고: 자료 외 일반 상식)" 라고 표시해서 보강만.
2. **구조 강제**: 답변은 반드시 마크다운 인덱스(`## 1.`, `## 2.`) 로 시작.
   짧은 답이라도 최소 `## 핵심 / ## 자세히` 2섹션 구성.
3. **수식**: 모든 수학·통계·물리 표기는 **LaTeX** 로 작성.
   - 인라인은 `$...$`, 별도 줄은 `$$...$$`.
   - 예: `$f'(x) = \\lim_{{h\\to 0}} \\frac{{f(x+h)-f(x)}}{{h}}$`
   - 평문 표기(`∫`, `√`, `x^2`) 절대 사용 금지 — 앱에서 깨져 보입니다.
   - 적분/시그마/분수/극한 모두 LaTeX 명령어 사용.
4. **예시 포함**: 개념 설명만 하지 말고 자료에 등장한 (또는 사용자가 적은) **구체 예시**를 1~2개 곁들이기.
5. **연습 문제**: 답변 마지막에 `## 스스로 점검` 섹션을 두고 짧은 자가 점검 질문 1~2개 제시.
6. **분량**: 너무 짧으면 성의 없어 보이고, 너무 길면 안 읽힘. 보통 600~1500자.
   사용자가 "짧게" / "한 줄로" 요청하면 그에 맞춤.
7. **어려운 용어**: 처음 등장 시 괄호 안에 풀이. 예: `편미분(partial derivative, 한 변수만 미분)`.
8. **사진 첨부 시**:
{image_note}

## 4. 출력 형식 (Output Format)
모든 답변은 다음 마크다운 템플릿을 따릅니다 (단, 질문 유형에 맞게 섹션 가감 가능).
**중요: 전체 답변을 코드블록으로 감싸지 마세요 — 백틱 3개(펜스)로 시작/종료하지 말고,
아래 헤더(`##`)와 본문을 펜스 없이 그대로 출력합니다.**

## 1. 핵심 한 줄
(질문에 대한 가장 짧은 답을 1~2문장으로)

## 2. 자세한 설명
- 개념 정의
- 자료 인용 (자료에서 어떤 부분에 있었는지 짧게)
- 관련 공식: $$수식$$

## 3. 예시 / 풀이 과정
1. (단계 1) ...
2. (단계 2) ...

## 4. 흔한 함정 / 주의
- ...

## 스스로 점검
- (확인 질문 1)
- (확인 질문 2)

## 5. 금지 사항 (Forbidden)
- **전체 답변을 코드블록(백틱 3개 펜스)으로 감싸기 — 마크다운이 코드로 깨져 보입니다.**
- 자료에 없는 내용을 "있다" 고 단정하기.
- 평문 수식 (`x^2`, `∫f(x)dx`).
- `\\frac` 대신 `/` 만 쓰기.
- 한 줄 답변으로 끝내기 (구조 무시).
- 영어로만 답하기 (반드시 한국어 위주).
- 학습과 무관한 잡담 / 의견 표명.

## 6. 자기 점검 (Self-check, 마지막 단계)
응답을 출력하기 직전 머릿속으로 확인:
- [ ] 마크다운 헤더가 `## 숫자.` 형식인가?
- [ ] 모든 수식이 `$...$` 또는 `$$...$$` 안에 있는가?
- [ ] 자료에 없는 내용이 단정형으로 들어가 있진 않은가?

---

## [학습 자료 파일명]
{filename or '(미상)'}

## [자료 본문]
{file_text}
{notes_block_full}"""


# ---------------------------------------------------------------------------
# 메시지 빌더
# ---------------------------------------------------------------------------

def _build_user_content(
    *, question: str, image_data_urls: list[str] | None
) -> list[dict] | str:
    """multimodal user content 빌더.

    - 이미지가 있으면 OpenAI 비전 포맷 (list of content parts) 사용.
    - 없으면 단순 문자열 (토큰 약간 절약).
    """
    if not image_data_urls:
        return question
    parts: list[dict] = [{"type": "text", "text": question}]
    for url in image_data_urls[:MAX_IMAGES_PER_TURN]:
        if not url or not isinstance(url, str):
            continue
        parts.append({
            "type": "image_url",
            "image_url": {"url": url, "detail": "high"},
        })
    return parts


def _build_messages(
    *,
    system_prompt: str,
    history: list[tuple[str, str]],
    user_question: str,
    image_data_urls: list[str] | None,
) -> list[dict]:
    msgs: list[dict] = [{"role": "system", "content": system_prompt}]
    # 히스토리는 단순 텍스트 (이전 이미지까지 전송하면 토큰 폭증, 마지막 turn 만 이미지).
    for role, body in history:
        if role not in ("user", "assistant"):
            continue
        msgs.append({"role": role, "content": body})
    msgs.append({
        "role": "user",
        "content": _build_user_content(
            question=user_question, image_data_urls=image_data_urls
        ),
    })
    return msgs


# ---------------------------------------------------------------------------
# 동기 (1-shot) 호출
# ---------------------------------------------------------------------------

async def ask_tutor(
    *,
    file_text: str,
    filename: str | None,
    history: Iterable[tuple[str, str]],
    user_question: str,
    image_data_urls: list[str] | None = None,
    user_notes: list[tuple[str | None, str]] | None = None,
) -> tuple[str, int]:
    """튜터에게 한 번 질문하고 응답을 반환. (answer_body, tokens) 튜플.

    `image_data_urls`: 각 원소는 `"data:image/jpeg;base64,..."` 형식의 데이터 URL.
    `user_notes`: 사용자가 같은 파일에 작성한 노트 [(title, body), ...]. 최신순.
    """
    history_list = list(history)[-MAX_HISTORY_TURNS:]
    notes_block = _format_notes(user_notes)

    system_prompt = _build_system_prompt(
        file_text=file_text,
        filename=filename,
        notes_block=notes_block,
        has_images=bool(image_data_urls),
    )

    messages = _build_messages(
        system_prompt=system_prompt,
        history=history_list,
        user_question=user_question,
        image_data_urls=image_data_urls,
    )

    client = _get_client()
    try:
        response = await client.chat.completions.create(
            model=settings.OPENAI_TUTOR_MODEL,
            temperature=settings.OPENAI_TUTOR_TEMPERATURE,
            max_tokens=settings.OPENAI_TUTOR_MAX_TOKENS,
            messages=messages,
        )
    except OpenAIError as exc:
        logger.exception("OpenAI tutor call failed")
        raise TutorError(f"OpenAI request failed: {exc}") from exc

    answer = response.choices[0].message.content or ""
    tokens = response.usage.total_tokens if response.usage else 0
    return answer.strip(), tokens


# ---------------------------------------------------------------------------
# 스트리밍 (SSE) 호출
# ---------------------------------------------------------------------------

async def ask_tutor_stream(
    *,
    file_text: str,
    filename: str | None,
    history: Iterable[tuple[str, str]],
    user_question: str,
    image_data_urls: list[str] | None = None,
    user_notes: list[tuple[str | None, str]] | None = None,
) -> AsyncIterator[str]:
    """튜터 응답을 토큰 단위로 yield. 각 yield 는 응답 텍스트 delta 청크.

    사용자가 응답을 기다리는 동안 "AI 가 생각 중" 으로만 표시하면 지루하므로
    SSE 로 흘려보내고 iOS 가 점진적으로 화면에 표시한다.
    """
    history_list = list(history)[-MAX_HISTORY_TURNS:]
    notes_block = _format_notes(user_notes)

    system_prompt = _build_system_prompt(
        file_text=file_text,
        filename=filename,
        notes_block=notes_block,
        has_images=bool(image_data_urls),
    )

    messages = _build_messages(
        system_prompt=system_prompt,
        history=history_list,
        user_question=user_question,
        image_data_urls=image_data_urls,
    )

    client = _get_client()
    try:
        stream = await client.chat.completions.create(
            model=settings.OPENAI_TUTOR_MODEL,
            temperature=settings.OPENAI_TUTOR_TEMPERATURE,
            max_tokens=settings.OPENAI_TUTOR_MAX_TOKENS,
            messages=messages,
            stream=True,
        )
    except OpenAIError as exc:
        logger.exception("OpenAI tutor stream call failed")
        raise TutorError(f"OpenAI request failed: {exc}") from exc

    try:
        async for chunk in stream:
            if not chunk.choices:
                continue
            delta = chunk.choices[0].delta.content
            if delta:
                yield delta
    except OpenAIError as exc:
        logger.exception("OpenAI tutor stream interrupted")
        raise TutorError(f"OpenAI stream interrupted: {exc}") from exc
