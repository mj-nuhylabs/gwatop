# Turbo AI 기능 조사 & GwaTop 적용 계획

> 작성일: 2026-06-03 · 대상: GwaTop (AI 기반 대학생 학습 자동화 앱)
> 상태: **계획 단계 (미적용)** — 조사·매핑·단계별 적용 계획까지만. 구현은 별도 진행.

---

## 0. 요약 (TL;DR)

GwaTop은 Turbo AI의 **"학습 도구" 축**(요약·퀴즈·플래시카드·마인드맵·암기·주요주제·AI 튜터·노트)을 이미 거의 따라잡았고, **"학사 자동화" 축**(강의계획서 파싱 → 시험/과제 자동등록 → 캘린더/시간표 → D-day 자동 ToDo → APNs 푸시 → 강의자료 과목/주차 자동분류)은 **Turbo AI에 아예 없는 GwaTop의 압도적 차별점**이다.

따라서 이 계획의 핵심은 *Turbo의 강점(캡처·미디어 축)을 GwaTop의 강한 기반 위에 흡수*하는 것이며, 진짜 갭은 다음 네 가지다.

1. **캡처** — 실시간 강의 녹음, 오디오/동영상 업로드, YouTube 인제스트, STT(전사)
2. **적응형 간격반복(FSRS)** — 현재는 단순 known/unknown만 존재 (이미 자체 로드맵 Day 5)
3. **팟캐스트(TTS)** — 노트 → 오디오 변환
4. **협업** — 노트 공유 / 공동편집 / 인라인 코멘트

### 핵심 통찰 — 파이프라인 재활용
GwaTop은 이미 `extract_text → analyze_file → generate_ai_content(6종)` + 튜터 파이프라인이 **텍스트만 있으면** 전부 동작한다. 따라서 **녹음/오디오/YouTube에서 transcript 텍스트만 뽑아 `files.extracted_text`에 넣으면, 요약·퀴즈·플래시카드·마인드맵·암기·주제·튜터가 코드 변경 없이 그대로 생성**된다. → **캡처 레이어만 붙이면 학습 기능 대부분이 자동으로 따라온다.** (Phase 1을 최우선에 두는 이유)

---

## 1. Turbo AI 전체 기능 조사

Turbo AI(구 TurboLearn AI, `turbo.ai`)는 "강의를 녹음/업로드하면 학습자료로 변환"하는 AI 노트테이커. 사용자 500만, iOS/Android/Web.

### A. 입력·캡처
- **실시간 강의 녹음** (앱 내 라이브 레코딩, 타임스탬프 정렬 전사) — *시그니처 기능*
- **오디오 파일 업로드**, **동영상 업로드**
- **YouTube 링크** → 노트/플래시카드 자동 생성
- **PDF / 교재 / 강의 슬라이드 / 논문** 업로드
- 다양한 악센트·전문용어 인식 ("99% 정확도, 30초 처리"를 마케팅)

### B. 노트
- **Rich Notes**: 다이어그램·수식·표·이모지 포함 구조화 노트 (계층 헤딩)
- **구글 닥스식 풀 에디터** + **라이브 AI 협업**(AI가 문서 수정·이슈 하이라이트·AI 코멘트 추가)
- 수학·화학·물리 다이어그램·코드 스니펫 렌더링
- **Transcript 보기**(원본 발화 텍스트), 노트/챗/트랜스크립트 **3-뷰**

### C. 학습 도구
- **플래시카드** 자동 생성 + **적응형 간격반복**(spaced repetition, 내 페이스에 적응) + **약점/진도 추적**
- **퀴즈**: 무제한 생성, **난이도 조절**(기초→시험수준), **답마다 상세 해설**, 챕터/주제 선택
- **팟캐스트**: 노트를 오디오로 변환, **길이 조절**, **오프라인 다운로드**

### D. 챗·튜터
- **노트와 챗**(AI 튜터): 업로드한 내 자료 기반 Q&A, **여러 자료 교차 검색**(개인 코퍼스 쿼리)

### E. 조직화·동기화
- **폴더**(수업/학기/과목별), 검색, **웹·태블릿·모바일 자동 동기화**

### F. 협업
- **원클릭 노트 공유**, **실시간 공동편집**(팀원 편집 실시간 표시), **인라인 코멘트/토론**

### G. 기타
- 큐레이션 도서관(교재/학술서), 하이라이트·주석, 다국어 지원, 데스크톱 앱(예정)

---

## 2. Turbo AI ↔ GwaTop 매핑 (전 기능)

| Turbo AI 기능 | GwaTop 현황 | 적용 위치/판단 |
|---|---|---|
| **─ 입력·캡처 ─** | | |
| PDF/슬라이드/논문 업로드 | ✅ 보유 | `files` + S3 presigned |
| **실시간 강의 녹음** | ❌ 없음 | **최대 갭 — 신규** |
| 오디오 파일 업로드 | ❌ (`pdf`만 허용) | 신규 |
| 동영상 업로드 | ❌ 없음 | 신규(오디오 추출) |
| **YouTube 링크 인제스트** | ❌ 없음 | 신규 |
| **─ 노트 ─** | | |
| 자동 구조화 노트(Rich Notes) | 🟡 부분 (summary+topics+memorize 조합) | `rich-notes` 컨텐츠 추가 |
| 수식/화학/코드 렌더 | ✅ 보유 (`latex_repair.py`) | — |
| 구글닥스식 에디터 | 🟡 부분 (`user_notes` 단순 CRUD) | 에디터 고도화 |
| 라이브 AI 협업/코멘트 | ❌ 없음 | tutor/summarizer 재활용 |
| **Transcript 보기** | ❌ 없음 | STT와 함께 신규 탭 |
| **─ 학습 도구 ─** | | |
| 플래시카드 | ✅ 보유(+ known/unknown) | — |
| **적응형 간격반복(SRS)** | ❌ 단순 known/unknown만 | **FSRS 신규** (이미 로드맵 Day5) |
| 퀴즈 | ✅ 보유 | — |
| 퀴즈 정답 해설 | ✅ **이미 보유** (`explanation`) | — |
| 퀴즈 난이도 조절 | ❌ 없음 | 프롬프트 파라미터 (**퀵윈**) |
| 챕터/범위 선택 | ✅ 보유 (`scope` pages) | — |
| 약점/진도 추적 | 🟡 부분 (flashcard만) | `quiz_attempts` 테이블 |
| **팟캐스트(TTS)** | ❌ 없음 | **신규** (TTS) |
| **─ 챗·튜터 ─** | | |
| 노트와 챗(AI 튜터) | ✅ 보유 (멀티턴+비전+스트리밍, **Turbo보다 우수**) | — |
| 자료 교차 검색(코퍼스 RAG) | ❌ 파일 단위뿐 | 과목 단위 RAG (pgvector 활용) |
| **─ 조직화·동기화 ─** | | |
| 폴더 | ✅ 학기/과목 계층 (**더 우수**) | — |
| 크로스 디바이스 동기화 | ✅ iOS+web+백엔드 | — |
| **─ 협업 ─** | | |
| 공유/공동편집/인라인 코멘트 | ❌ 없음 | 신규 (멀티유저화) |
| **─ 기타 ─** | | |
| 큐레이션 도서관 | ❌ 없음 | **범위 외 권장** |
| 다국어 | ❌ 한국어 특화 | 범위 외/선택 |

### ⭐ Turbo AI엔 아예 없는 GwaTop 고유 강점 (재구축 금지)
강의계획서 파싱 → **시험/과제 일정 자동등록** → **캘린더/시간표** → **D-day 자동 ToDo** → **APNs 푸시 알림**, 강의자료 **과목/주차 자동분류**. Turbo는 "학습자료 생성기"일 뿐 **학사 일정 자동화가 전무**하다. 여기가 GwaTop의 차별점이므로 그대로 두고, Turbo의 "캡처·미디어" 축만 흡수한다.

---

## 3. 적용 계획 (어디에·어떻게)

### Phase 1 — 캡처 패리티 (데모 임팩트 최대, 권장 1순위)

**1a. 오디오/동영상 업로드 + Whisper STT**
- **백엔드**: `app/core/config.py`의 `ALLOWED_FILE_TYPES`에 `m4a,mp3,wav,mp4` 추가 → 신규 `app/services/transcription.py`(OpenAI `whisper-1`/`gpt-4o-transcribe`, 25MB 초과 시 pydub로 청크 분할) → 신규 Celery 태스크 `transcribe_audio_task`(S3 다운로드 → 전사 → `files.extracted_text` 저장 → 기존 `analyze_file_task` 트리거). `confirm` 라우트에서 파일타입이 오디오면 `extract_text` 대신 `transcribe`로 분기.
- **스키마**: `files`에 `transcript`(타임스탬프 segment JSON), `duration_sec` 컬럼 추가 (마이그레이션 1건).
- **iOS**: `GwaTopFileUploadService` 재사용(이미 presigned PUT). 업로드 시트에 "오디오/영상" 옵션 추가.
- **caveat**: S3 CORS는 이미 `PUT/GET` 허용됨 → 오디오도 OK. 비용: Whisper 약 $0.006/분.

**1b. 실시간 강의 녹음 (Turbo 시그니처)**
- **iOS**: `AVAudioRecorder` 기반 신규 `GwaTopLectureRecordView.swift` — 녹음 버튼/타이머/일시정지, 백그라운드 녹음 권한, 종료 시 m4a를 1a 업로드 플로우로 전송. `GwaTopAIStudyView`에 "＋ 녹음" 진입점.
- **웹**: `MediaRecorder` API로 브라우저 내 녹음 → 동일 업로드.
- **효과**: "강의실에서 녹음 → 끝나면 요약·퀴즈·플래시카드 자동" 데모 가능.

**1c. YouTube 링크 인제스트**
- **백엔드**: 신규 `app/services/youtube.py`(`youtube-transcript-api`로 자막 추출, 없으면 `yt-dlp`+Whisper) → 신규 라우트 `POST /courses/{id}/ingest/youtube` → `ingest_youtube_task`가 transcript를 `files`로 저장 후 동일 파이프라인.
- **iOS/웹**: "링크로 추가" 입력 필드.
- **caveat**: YouTube ToS·차단 가능성 → 자막 우선, 다운로드는 폴백.

**1d. Transcript 탭**
- **iOS/웹**: `GwaTopFileStudyView` / `/study/[fileId]`에 10번째 탭 "스크립트" 추가(타임스탬프 클릭 → 오디오 시크). 신규 라우트 `GET /files/{id}/transcript`.

> 규모: **L** (가장 큼). 데모 가치: ★★★★★. 1a+1b+1d를 한 묶음으로 먼저.

---

### Phase 2 — 학습 깊이: FSRS 간격반복 + 퀴즈 고도화 (이미 로드맵에 있음)

**2a. FSRS 적응형 간격반복** (= 미구현 "학습탭"의 핵심)
- **백엔드**: `user_flashcard_status` 확장(`stability,difficulty,due,reps,lapses,last_review`) 또는 신규 `flashcard_reviews` 테이블. `py-fsrs` 라이브러리. 신규 라우트 `POST /files/{id}/flashcards/review`(grade 1~4 → 다음 due 계산), **`GET /review/due`(전 과목 오늘 복습할 카드 글로벌 큐)**. Celery Beat에 "오늘 복습 N장" 알림(기존 `notify_due_dday`와 동일 패턴).
- **iOS**: Again/Hard/Good/Easy 버튼 복습 모드 + 홈/학습탭에 "오늘의 복습" 카드. → 비어있던 학습탭을 채움.
- **웹**: 동일.

**2b. 퀴즈 난이도 + 약점 추적**
- **백엔드**: `generate_quiz`에 `difficulty`(기초/중간/시험) 파라미터 추가(프롬프트 1줄) — **해설은 이미 있음**(`content_generators.py:148`). 신규 `quiz_attempts` 테이블에 정오답 기록 → 약점 주제 집계 라우트.
- **iOS/웹**: 난이도 선택 토글 + "약점 분석" 뷰.

> 규모: **M**. 난이도 토글은 **퀵윈(S)**. 가치: ★★★★.

---

### Phase 3 — 미디어·표현: 팟캐스트 + 리치 자동노트

**3a. 팟캐스트 (NotebookLM식)**
- **백엔드**: 신규 `app/services/podcast.py` — 요약/노트를 LLM으로 2인 대화 스크립트화 → OpenAI TTS(`gpt-4o-mini-tts`)로 mp3 합성 → S3 저장. `ai_contents`에 `content_type="podcast"`(S3 key+duration 저장), 신규 `generate_podcast_task`. 비용 커서 **prefetch 말고 on-demand만**.
- **iOS**: "팟캐스트" 탭 + `AVPlayer` 재생/오프라인 다운로드.
- **웹**: `<audio>` 플레이어.

**3b. 리치 자동노트 content_type**
- **백엔드**: `GENERATOR_REGISTRY`에 `rich-notes` 추가(헤딩/표/이모지 구조화 노트 프롬프트) — 기존 6종과 동일 구조라 추가 비용 적음.

> 규모: 3a **M**, 3b **S**. 데모 가치(팟캐스트): ★★★★.

---

### Phase 4 — 협업 & 고급 (데모 후순위)

- **4a. 과목 단위 RAG 튜터** — 이미 pgvector 보유. 파일별 chunk 임베딩 테이블 추가 → `POST /courses/{id}/tutor`가 과목 전 자료에서 검색. (현 튜터는 파일 단위) — 규모 **M~L**, 가치 ★★★★.
- **4b. 노트 공유/공동편집/인라인 코멘트** — `files.uploaded_by_user_id`로 멀티유저 준비는 돼 있으나 course 멤버십·공유링크 등 멀티테넌시 도입 필요 — 규모 **L**, 데모 가치 ★★.
- **4c. 리치 에디터 + AI 인라인 코멘트** — 웹은 TipTap/Lexical, iOS는 부담 큼. 경량 버전으로 "AI로 노트 다듬기" 버튼(tutor 재활용)부터 — 규모 **L**, 가치 ★★★.

---

## 4. 권장 실행 순서 (투자자/사용자 데모 목표 기준)

| 순위 | 항목 | 규모 | 데모 임팩트 | 비고 |
|---|---|---|---|---|
| **1** | Phase 1a+1b+1d (녹음+STT+스크립트) | L | ★★★★★ | 파이프라인 재활용으로 학습기능 자동 확장 |
| **2** | Phase 3a (팟캐스트) | M | ★★★★ | "wow" 데모 |
| **3** | Phase 2a (FSRS) + 2b 난이도 토글 | M | ★★★★ | 학습탭 채움, 이미 로드맵 |
| **4** | Phase 1c (YouTube) | M | ★★★ | 입력 다양화 |
| **5** | Phase 3b, 4a (리치노트, 과목 RAG) | S~L | ★★★ | 품질 심화 |
| 후순위 | Phase 4b/4c (협업/리치에디터), 도서관·다국어 | L | ★★ | 범위 외 권장 |

**공통 선결**: `ALLOWED_FILE_TYPES` 확장 + 신규 컬럼 마이그레이션 1~2건 → EC2 배포 절차(`alembic upgrade head` + `systemctl restart gwatop-celery gwatop-uvicorn`)는 기존 운영 메모 그대로. 비용 모니터링(Whisper/TTS)과 Celery 타임리밋(이미 180/300s 하드닝됨 — 긴 오디오는 청크 분할 필수) 주의.

---

## 5. 참고 출처 (Sources)

- Turbo AI 공식: <https://www.turbo.ai/>
- Turbo AI for Students: <https://www.turbo.ai/for-students>
- App Store (Turbo AI Notetaker): <https://apps.apple.com/us/app/turbo-ai-notetaker/id6502794561>
- Product Hunt: <https://www.producthunt.com/products/turbo-ai-turbolearn-ai-2>
- Unite.AI 리뷰: <https://www.unite.ai/turbolearn-ai-review/>
- TechCrunch (5M users): <https://techcrunch.com/2025/10/23/20-year-old-dropouts-built-ai-notetaker-turbo-ai-to-5-million-users/>
- HyScaler (vs NotebookLM): <https://hyscaler.com/insights/turbolearn-ai-pricing-reviews-features/>

---

*GwaTop 현황 매핑은 2026-06-03 기준 코드베이스 직접 조사 결과. 파일 경로·기능 유무는 구현 착수 시점에 재확인 권장.*
