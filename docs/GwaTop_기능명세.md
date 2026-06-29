# GwaTop 전체 기능 명세서

> **과탑(GwaTop)** — AI 기반 대학생 학습 자동화 앱
> 강의계획서·강의자료를 올리기만 하면, 시간표·일정·할 일·AI 학습 콘텐츠가 자동으로 생성됩니다.

이 문서는 GwaTop의 **모든 기능**을 사용자/개발자 관점에서 구체적으로 설명합니다.
(작성 기준: `dev` 브랜치 코드 전수 조사, 최종 업데이트 2026-06-07)

---

## 목차

1. [한눈에 보는 GwaTop](#1-한눈에-보는-gwatop)
2. [시스템 구성](#2-시스템-구성)
3. [핵심 사용자 여정](#3-핵심-사용자-여정-한-번-올리면-끝)
4. [회원가입 · 로그인](#4-회원가입--로그인)
5. [메인 탭 ① 홈 (대시보드)](#5-메인-탭--홈-대시보드)
6. [메인 탭 ② 캘린더 · 시간표](#6-메인-탭--캘린더--시간표)
7. [메인 탭 ③ 학습 (강의자료)](#7-메인-탭--학습-강의자료)
8. [메인 탭 ④ Todo (할 일)](#8-메인-탭--todo-할-일)
9. [메인 탭 ⑤ 설정](#9-메인-탭--설정)
10. [파일 업로드 시스템](#10-파일-업로드-시스템)
11. [AI 자동화 파이프라인 (핵심)](#11-ai-자동화-파이프라인-핵심)
12. [파일 학습 화면 — 9개 학습 탭](#12-파일-학습-화면--9개-학습-탭)
13. [AI 학습 콘텐츠 종류 상세](#13-ai-학습-콘텐츠-종류-상세)
14. [AI 튜터](#14-ai-튜터)
15. [할 일 자동 생성 규칙](#15-할-일-자동-생성-규칙)
16. [푸시 알림](#16-푸시-알림)
17. [관리자 기능](#17-관리자-기능)
18. [데이터 모델](#18-데이터-모델)
19. [백엔드 API 레퍼런스](#19-백엔드-api-레퍼런스)
20. [기술 스택 · 인프라](#20-기술-스택--인프라)
21. [웹 버전 (gwatop-web)](#21-웹-버전-gwatop-web)

---

## 1. 한눈에 보는 GwaTop

GwaTop은 대학생이 학기를 시작할 때 받는 **강의계획서(Syllabus)** 와 학기 중 받는 **강의자료(PDF/PPT 등)** 를 업로드하면, 아래를 **전부 자동으로** 만들어 주는 앱입니다.

| 올리는 것 | 자동으로 생기는 것 |
|---|---|
| 강의계획서 PDF | 과목 자동 생성, 시간표, 시험·과제 일정, 단계별 할 일, 주차별 학습 계획 |
| 강의자료 PDF | 과목 자동 매칭, 주차 자동 분류, AI 요약·퀴즈·플래시카드·마인드맵·암기노트·핵심개념 |

**한 줄 요약:** "파일만 던지면 학습 관리가 끝난다."

핵심 차별점:
- **무차별 업로드** — 강의계획서인지 강의자료인지, 어느 과목인지 사용자가 고르지 않아도 AI가 알아서 판별·분류
- **AI 학습 콘텐츠 자동 생성** — 자료 하나당 6종(요약/퀴즈/플래시카드/마인드맵/암기/핵심개념)의 학습 도구
- **파일 기반 AI 튜터** — 업로드한 자료 내용을 근거로 질문에 답하는 1:1 조교
- **수식 지원** — KaTeX 기반 LaTeX 수식 렌더링으로 이공계 자료도 정확히 표현

---

## 2. 시스템 구성

GwaTop은 3개의 독립 컴포넌트로 구성됩니다.

```
┌─────────────────┐     ┌──────────────────┐     ┌─────────────────┐
│   iOS 앱        │     │   웹 앱           │     │   백엔드        │
│  (SwiftUI)      │     │  (Next.js 16)    │     │  (FastAPI)      │
│                 │     │  app.gwatop.co.kr │     │ api.gwatop.co.kr│
└────────┬────────┘     └────────┬─────────┘     └────────┬────────┘
         │                       │                         │
         └───────────────────────┴─────────────────────────┘
                          HTTPS / JWT
                                                            │
                       ┌────────────────────────────────────┤
                       │              │           │          │
                   PostgreSQL      Redis      Celery       AWS S3
                  (+pgvector)    (큐/캐시)   (AI 워커)   (파일저장)
                                                            │
                                                       OpenAI API
                                                  (GPT-4o-mini, embeddings)
```

| 컴포넌트 | 기술 스택 | 역할 |
|---|---|---|
| **iOS 앱** | SwiftUI, SwiftData, PDFKit, PencilKit, WKWebView(KaTeX) | 메인 클라이언트 |
| **웹 앱** | Next.js 16(App Router) + Turbopack, React 19 | iOS 기능 패리티 웹 버전 |
| **백엔드** | FastAPI(async), SQLAlchemy, Alembic | API 서버 |
| **DB** | PostgreSQL 16 + pgvector | 데이터 저장 |
| **큐/캐시** | Redis | Celery 브로커 + 파싱 결과 캐시 |
| **워커** | Celery (prefork) | AI 비동기 처리 |
| **스토리지** | AWS S3 (presigned URL) | 원본 파일 |
| **AI** | OpenAI GPT-4o-mini, text-embedding-3-small | 파싱·분류·생성 |
| **인증** | JWT (Access 60분 / Refresh 30일) + Google 로그인 | |
| **푸시** | APNs (aioapns) | D-Day·분류완료 알림 |

API 기본 정보:
- **Base URL**: `https://api.gwatop.co.kr`
- **Prefix**: `/v1`
- **인증**: `Authorization: Bearer <access_token>`

---

## 3. 핵심 사용자 여정 — "한 번 올리면 끝"

GwaTop의 모든 기능은 이 흐름을 중심으로 설계되어 있습니다.

```
[1] 학기 초 — 강의계획서 PDF 여러 개를 한꺼번에 업로드
       │
       ▼  (백그라운드 AI 처리, 5~30초)
   ┌───────────────────────────────────────────────┐
   │ • 과목 자동 생성 (이름·교수·강의실·학점)        │
   │ • 시간표 자동 구성 (요일·교시)                  │
   │ • 시험/과제 일정 자동 등록 (캘린더 반영)        │
   │ • 단계별 할 일 자동 생성 (D-14/7/3/1 등)        │
   │ • 주차별 학습 주제 추출 (자료 분류용 기준점)    │
   └───────────────────────────────────────────────┘
       │
[2] 학기 중 — 강의자료 PDF를 무차별 업로드 (과목/주차 선택 불필요)
       │
       ▼  (백그라운드 AI 처리)
   ┌───────────────────────────────────────────────┐
   │ • 어느 과목인지 자동 매칭 (본문 머리글 + 파일명)│
   │ • 몇 주차인지 자동 분류 (파일명 + 임베딩 유사도)│
   │ • AI 요약 자동 생성                             │
   └───────────────────────────────────────────────┘
       │
[3] 학습 — 파일을 열면 6종 AI 학습 도구 + AI 튜터 + 노트 제공
       │
[4] 일상 — 홈 대시보드에서 오늘 할 일·다음 일정 확인, 푸시 알림 수신
```

업로드 후 사용자가 화면에 묶여 있는 시간은 **3~5초**뿐입니다. 무거운 파싱은 전부 백그라운드(Celery)로 빠지고, 완료되면 캘린더·학습·Todo 탭이 **자동으로 새로고침**됩니다.

---

## 4. 회원가입 · 로그인

### 4.1 인증 방식
- **이메일 + 비밀번호** 회원가입/로그인 (비밀번호 8자 이상)
- **Google 소셜 로그인** — Google ID 토큰 검증 후 자동 가입/기존 계정 병합 (`email_verified` 확인)
- **JWT 토큰** — Access(60분) / Refresh(30일), 토큰 타입 분리로 혼용 방지

### 4.2 회원가입 화면
입력 항목: 이름, 이메일(+인증코드), 비밀번호(+확인), 학교(한국 대학 검색 picker), 학번, 추천인 코드(선택).
> 학교·학번·추천인은 UI에서 수집하며, 백엔드는 현재 email/password/name을 핵심으로 처리(확장 예정 필드 포함).

### 4.3 로그인 화면
- 이메일/비밀번호 입력 (pill 스타일 필드, 비밀번호 show/hide)
- **로그인 유지** 체크박스 → 다음 실행 시 자동 로그인
- Google Sign-In 버튼
- 세션 만료(401) 시 자동 로그아웃 처리

### 4.4 프로필 관리 (`/v1/auth/me`)
- 프로필 조회/수정(이름·이메일), 비밀번호 변경
- 소셜 로그인 계정은 이메일/비밀번호 변경 불가

### 4.5 스플래시
- **부팅 스플래시** — 콜드 스타트 직후 0.6초, 로고 노출로 깜빡임 방지
- **로딩 스플래시** — 로그인/세션 복구 후 데이터 워밍업(`warmup()`) 진행률 바 표시

---

## 5. 메인 탭 ① 홈 (대시보드)

하단 탭 5개 중 첫 번째. `GET /v1/home/dashboard` 한 번으로 모든 데이터를 받아 구성합니다.

**구성 요소:**
- **오늘 일정** (`today_schedules`) — 오늘(KST 자정~자정) 시험/과제/강의
- **급한 할 일** (`upcoming_todos`) — 우선순위(high→medium→low) + 마감일 순 미완료 할 일
- **이번 주 진행률** (`this_week_summary`) — 완료/전체 개수와 완료율(0~100%)
- **다음 일정 카드** (`next_event`) — 가장 가까운 미래 일정 + D-Day 표시
- **과목 카드** — 과목별 색상·진행률·다음 일정

**바로가기:**
- **무차별 파일 업로드 버튼** — 홈에서 바로 파일을 던지면 강의계획서/강의자료 자동 구분 ([10장](#10-파일-업로드-시스템))
- 새 학기/과목 추가(설정 이동)

---

## 6. 메인 탭 ② 캘린더 · 시간표

한 탭 안에서 **캘린더**와 **시간표** 두 화면을 전환합니다.

### 6.1 캘린더
- **월간 그리드** (일~토), 날짜별 일정 점(dot) 표시 — `GET /v1/schedules/calendar/summary`로 일별·타입별 카운트만 가볍게 조회
- 선택한 날짜의 일정 상세 목록(시간순)
- **서버 일정 + Apple 캘린더 일정 병합 표시** (설정에서 연동 토글)
- 가장 가까운 일정으로 자동 월 점프
- **FAB(+) 스피드다이얼**: 강의계획서 업로드 / 일정 직접 추가

### 6.2 시간표
- 주간 그리드(월~일) × 시간대에 과목 블록 자동 배치 (강의계획서에서 추출한 `class_times` 기반)
- 블록에 과목명·강의실 표시(강의실 줄바꿈 개선)
- **시간 겹침 감지** — 충돌 슬롯이 있으면 배너로 알리고 어느 수업을 남길지 선택
- 탭 타이틀에 **학기 이름** 노출, 여러 학기 업로드 시 학기 드롭다운으로 전환
- + 버튼으로 시간표 과목 수동 추가

### 6.3 일정 직접 관리
- **일정 추가/수정/삭제** (`GwaTopScheduleEditSheet`): 과목·제목·유형·날짜·설명
- 일정 유형: 강의(lecture) / 과제(assignment) / 시험(exam) / 모임(meeting) / 업로드(upload) / 커스텀(custom)
- 일정 생성·수정 시 연결된 **자동 할 일이 함께 재생성**됨

### 6.4 파싱 진행 배너
강의계획서가 백그라운드 파싱 중이면 상단에 진행 배너가 뜨고, 완료되면 캘린더가 자동 새로고침됩니다.

---

## 7. 메인 탭 ③ 학습 (강의자료)

업로드한 강의자료를 **과목별로 정리**하고 학습 기능의 입구가 되는 탭.

**구성:**
- "학습" 헤더 + **자료 검색**(전체 과목 파일명 대상)
- 과목별 카드(펼침): 과목명·파일 수, 그 아래 자료 행(파일명·주차·업로드일·상태 배지)

**파일 상태 배지:**

| 상태 | 표시 | 의미 |
|---|---|---|
| pending/uploading/processing/classifying | 회전 스피너 | 업로드·추출·분류 진행 중 |
| `classified` | 🟢 준비 완료 (+주차) | 주차 분류 완료 |
| `unclassified` | ⚪ 미분류 | 주차 자동 분류 실패(수동 지정 가능) |
| `parsed` | — | 강의계획서 파싱 완료 |
| `failed` | 🔴 오류 | 처리 실패 |

**동작:**
- 분류 진행 중인 파일이 있으면 **3초마다 자동 폴링**으로 상태 갱신
- 강의계획서 파싱 완료 → 신규 과목/파일 **즉시 목록 반영**
- 파일 클릭 → **파일 학습 화면**(9개 탭) 전체화면 진입 ([12장](#12-파일-학습-화면--9개-학습-탭))
- 상단 업로드 진행 카드로 백그라운드 업로드 상태 노출

---

## 8. 메인 탭 ④ Todo (할 일)

주간 할 일·과제를 관리하는 탭. 미니멀 리디자인(홈 디자인 언어 통일).

**구성:**
- 상단 필터 탭: **전체 / 활성 / 완료**
- 과목별 그룹 섹션(접기/펴기, 과목 색상 틴트)

**정렬:** 우선순위(high>medium>low) → 마감일 오름차순 (완료 항목은 마감일 순)

**행 내용:** 체크박스 · 제목 · 마감일+D-Day · 우선순위 배지(빨강/주황/파랑)

**기능:**
- 체크박스/스와이프로 완료 토글 (중복 요청 방지)
- Pull-to-refresh
- 강의계획서 파싱이 만든 **자동 할 일이 즉시 반영**
- 할 일 직접 추가/수정/삭제도 가능 (과목·제목·마감일·우선순위)

> 자동 할 일 생성 규칙은 [15장](#15-할-일-자동-생성-규칙) 참고.

---

## 9. 메인 탭 ⑤ 설정

**계정**
- 사용자 정보(이름·이메일), 로그아웃

**학사 정보**
- **학기/과목 관리** (`GwaTopAcademicManagementView`)
  - 학기 목록, 활성 학기 표시(★) — 활성 학기만 일정/과제 대상
  - 학기 생성/이름변경/삭제/활성 전환 (스와이프)
  - 과목 목록 → 과목 생성/수정/삭제 (이름·교수·색상·학점·강의실·시간표)
- **내 자료 관리** (`GwaTopMyDataManagementView`)
  - 학사 정보 + 과목별 업로드 파일 목록 → 파일 학습 화면 진입

**앱 설정**
- **Apple 캘린더 연동** 토글 (권한 자동 요청)
- **외관** 선택: 시스템 / 라이트 / 다크

**관리자** (화이트리스트 이메일만 노출)
- 관리자 페이지 진입 링크 ([17장](#17-관리자-기능))

---

## 10. 파일 업로드 시스템

GwaTop은 **3가지 업로드 경로**를 제공하며, 모두 S3 Presigned URL 방식(보안·대역폭 절약)을 씁니다.

### 10.1 업로드 경로

| 경로 | 사용자 선택 | 동작 |
|---|---|---|
| **무차별(자동) 업로드** | 아무것도 안 고름 | AI가 강의계획서/강의자료 판별 → 과목·주차 자동 결정 |
| **강의계획서 업로드** | 강의계획서임을 지정 | 파싱 → 과목 자동 생성/매칭 |
| **강의자료 업로드** | 과목 지정 | 해당 과목에 넣고 주차 자동 분류 |

### 10.2 멀티 파일 자동 업로드
- 여러 파일을 한 번에 선택 가능 (배치, 최대 30개)
- **강의계획서를 먼저 처리한 뒤 강의자료를 처리** — 과목이 먼저 만들어져야 자료가 정확히 매칭되기 때문 (`POST /v1/files/auto/batch-confirm`)

### 10.3 업로드 흐름 (3단계)
```
1) presigned-url 발급  → 파일 크기·타입 사전 검증, DB에 File(status=pending) 생성
2) S3로 직접 PUT 업로드 (Content-Type 명시)
3) confirm 호출         → 텍스트 추출 백그라운드 태스크 트리거 (멱등 처리)
```

### 10.4 지원 포맷
- **현재 운영 정책: PDF만 허용** (`ALLOWED_FILE_TYPES="pdf"`)
- 모델·UI는 pptx/docx/image도 인지하나, 텍스트 추출기 추가 전까지 비-PDF는 거부(415)

### 10.5 업로드 UX 특징
- confirm 직후 시트를 바로 닫고 **워처(watcher)** 가 백그라운드 진행을 추적
- 파싱 완료 시 캘린더/학습/Todo 자동 새로고침 (스피너 없는 silent reload)

---

## 11. AI 자동화 파이프라인 (핵심)

업로드된 파일은 **Celery 비동기 워커**에서 단계별로 처리됩니다. 이 파이프라인이 GwaTop의 심장입니다.

```
파일 업로드 (confirm)
   │
   ▼
[1] extract_text_task ──── 텍스트 추출
   │   • PDF: PyMuPDF로 페이지별 텍스트 추출
   │   • OCR 폴백: 텍스트 300자 미만(스캔/손글씨)이면
   │            GPT-4o-mini 비전으로 페이지 이미지 OCR (최대 50p 병렬)
   │   • files.extracted_text 저장 → status=extracted
   │
   ├──[자동 모드]── detect_kind ── 강의계획서 vs 강의자료 판별
   │                 (휴리스틱 키워드 우선, 애매하면 GPT-4o-mini 단답 분류)
   │
   ├─▶ (강의계획서) ────────────────┐   ├─▶ (강의자료) ──────────────┐
   ▼                                │   ▼                            │
[2] parse_syllabus_task            │  [3] classify_file_task         │
   • PyMuPDF 표 추출로 주차표 선확보│     • 과목 자동 매칭            │
   • GPT-4o-mini JSON 파싱:        │       (본문 머리글 "과목명(코드)"│
     과목 메타 / 주차 / 시험 / 과제 │        우선 → 파일명 → LLM)     │
   • 정규식 후처리로 누락 일정 회수 │     • 주차 자동 분류:            │
   • 결과 저장:                    │       파일명 정규식(주차/week/ch)│
     - Course 자동 생성/매칭       │       → 임베딩 코사인 유사도     │
     - 시간표(class_times)         │       (text-embedding-3-small)  │
     - Schedule(시험·과제) INSERT  │     • files.week 저장           │
     - Todo 자동 생성              │     → status=classified          │
     - 주차별 topic + 임베딩 캐시  │        / unclassified            │
   → status=parsed                 │                                 │
   │                               │   │                             │
   ▼ (병렬)                        │   ▼ (병렬)                       │
[2b] analyze_file_task             │  [3b] generate_summary_task     │
   → AI 분석본(analysis) 생성      │     → AI 요약(summary) 생성     │
       (이후 콘텐츠 생성의 공통입력)│                                 │
   └────────────────────────────────┴─────────────────────────────────┘
   │
   ▼
[4] (사용자가 학습 화면 진입 시) generate_ai_content_task
       퀴즈 / 플래시카드 / 마인드맵 / 암기 / 핵심개념 생성
```

### 11.1 강의계획서 파싱 상세
- **표 선추출** — PyMuPDF `find_tables()`로 주차표를 먼저 확보하면 LLM은 과목 메타·시험·과제만 처리(지연 50%↓, 토큰 절감)
- **텍스트 정제** — 페이지번호·반복헤더·무관 섹션(참고문헌 등) 제거로 입력 토큰 ~30%↓
- **캐시** — 동일 강의계획서 재파싱 시 Redis에서 7일 캐시
- **파싱 규칙(프롬프트)** — 한 셀 다중 일정 분리 / 퀴즈는 시험으로 / 과제는 마감일만 / 상대날짜(M/D)→절대날짜 변환 / 추측 금지
- **누락 회수** — GPT가 주차 메모(notes)에 남긴 시험·과제를 정규식으로 다시 긁어 보강

**파싱 결과 구조 (요약):**
```json
{
  "course":  { "name", "professor", "credit", "location",
               "class_times": [{"day","start_time","end_time"}],
               "total_weeks" },
  "weeks":   [{ "week_number", "topic", "notes" }],
  "exams":   [{ "title", "exam_date", "start_time", "end_time", "location" }],
  "assignments": [{ "title", "due_date", "description" }],
  "confidence": 0.0~1.0, "warnings": []
}
```

### 11.2 강의자료 과목 매칭 (정확도 우선순위)
1. **본문 머리글** — 자료 첫 부분의 `과목명 (코드)` 패턴 (예: "웹 개발 실무 (CSE 3401)") — 가장 신뢰
2. **파일명** — 분반마커(C1 등)·주차·순번 노이즈 제거 후 추출
3. **LLM 폴백** — GPT-4o-mini로 한국어 과목명 추정

→ 활성 학기 내 기존 과목과 퍼지 매칭, 없으면 신규 생성(색상 자동 배정).

### 11.3 주차 자동 분류 (2단계)
1. **파일명 정규식** — "3주차/주차3/week5/ch4/lec6/01_" 등 패턴별 신뢰도, 임계값 이상이면 즉시 채택
2. **임베딩 유사도** — 파일 텍스트 임베딩 vs 강의계획서 주차별 topic 임베딩 코사인 유사도로 최적 주차 결정 (캐시 재사용)
3. 둘 다 약하면 `unclassified` → 사용자가 수동 지정(`PATCH /files/{id}/week`)

### 11.4 사용 AI 모델

| 용도 | 모델 |
|---|---|
| 강의계획서 파싱 / 콘텐츠 생성 / 튜터 / OCR | GPT-4o-mini (일부 nano 포함) |
| 강의자료·강의계획서 종류/과목 분류(폴백) | GPT-4o-mini (단답) |
| 주차 분류·과목 매칭 유사도 | text-embedding-3-small |

---

## 12. 파일 학습 화면 — 9개 학습 탭

학습 탭(또는 내 자료)에서 파일을 열면 좌우 스크롤되는 **9개 학습 탭**이 나타납니다 (`GwaTopFileStudyView`).

| # | 탭 | 설명 |
|---|---|---|
| 1 | **PDF** | PDFKit 원본 뷰어 (pinch zoom, 썸네일 스트립, 페이지 캐시 30분) |
| 2 | **요약** | AI 자동 요약 (헤드라인·핵심포인트·섹션·학습팁), 가장 빠른 탭 |
| 3 | **AI 튜터** | 자료 내용 기반 1:1 질의응답 (스트리밍 응답, 이미지 첨부 가능) |
| 4 | **퀴즈** | AI 객관식+주관식 문제, 채점, "다른 문제로 새로 만들기" |
| 5 | **플래시카드** | 앞/뒤 카드 스와이프, "알아요/몰라요" 마킹, "더 만들기" |
| 6 | **마인드맵** | 트리 구조 개념도 (클라이언트 레이아웃 계산, 가지 펼치기/접기) |
| 7 | **암기** | 시험 대비 핵심 암기 포인트 (중요도 1~5) |
| 8 | **핵심개념(주요 주제)** | 처음 배우는 학생 기준 개념 설명 + 예시 |
| 9 | **노트** | 텍스트 노트 + 손글씨 노트(Apple Pencil) |

### 12.1 콘텐츠 로딩 동작
- 파일 진입 시 **prefetch** 호출 → 5종(퀴즈/플래시카드/마인드맵/암기/핵심개념)을 백그라운드 선생성
- 각 탭은 캐시 hit 시 즉시 표시, miss 시 "생성하기" → 8~15초 후 표시
- 항상 **"다시 만들기"** 버튼 제공

### 12.2 페이지 범위 선택
**퀴즈 · 플래시카드 · 암기 · 핵심개념** 탭은 "전체 페이지" 또는 "특정 페이지(예: 1-3, 5)"를 골라 해당 범위만 학습 콘텐츠를 만들 수 있습니다. (백엔드는 `scope`별로 콘텐츠를 따로 캐시)

### 12.3 특수 UI 요소
- **손글씨 노트** (`GwaTopInkCanvas`) — PencilKit 기반, 펜/지우개/색상, 손그림을 base64(PKDrawing)로 직렬화하여 텍스트 캡션과 함께 저장 (`[[INK_V1]]...` 포맷)
- **마인드맵** (`GwaTopMindmapCanvas`) — 루트 중심, 1단계 자식을 좌/우 균형 배치, 2단계 손자까지 L자 연결선, 색상은 과목 파스텔 팔레트
- **수식 렌더링** (`GwaTopMathText`) — LaTeX 신호 자동 감지 시 KaTeX(WKWebView)로 렌더링, 아니면 가벼운 SwiftUI Text, 오프라인 시 plain 텍스트 폴백. KaTeX/marked 자산은 **앱 번들 내장**(오프라인 동작)

---

## 13. AI 학습 콘텐츠 종류 상세

자료 하나(`file`)당 아래 콘텐츠가 페이지 범위(`scope`)별로 생성·캐시됩니다 (`ai_contents` 테이블).

| 종류 (`content_type`) | 출력 구조 | 용도 |
|---|---|---|
| **summary** | headline / key_points / sections / study_tip | 빠른 전체 요약 |
| **quiz** | 객관식(4지선다)+주관식 문제·정답 | 문제 풀이 자가점검 |
| **flashcard** | front(질문/용어) + back(답/정의) | 반복 암기 |
| **mindmap** | 트리(root→depth2, 최대 8자식×4손자) | 구조 파악 |
| **memorize** | category / text / importance(1~5) | 시험 직전 암기 |
| **topics** | title / body / examples | 개념 이해 |
| *analysis* (내부) | overview/main_concepts/key_terms/structure/exam_points | 위 콘텐츠들의 공통 입력(토큰 절약용, 사용자 비노출) |

**공통 설계:**
- 먼저 `analysis`(분석본)를 만든 뒤 이를 공통 입력으로 재사용 → 입력 토큰 대폭 절감
- 모든 수식은 **LaTeX**로 출력(KaTeX 렌더링), 깨진 백슬래시는 `repair_latex_in_payload()`로 후처리 복구
- 동시 워커 중복 생성 방지: `(file_id, content_type, scope)` 유니크 제약

**플래시카드 학습 추적** (`user_flashcard_status`):
- 카드별 "알아요(known)/몰라요(unknown)" 상태를 사용자별로 저장
- "더 만들기"는 기존 카드와 **중복되지 않는** 새 카드를 추가 (동기 생성)

---

## 14. AI 튜터

업로드한 자료를 근거로 답하는 **파일별 1:1 AI 조교**.

**할 수 있는 것:**
- 자료 내용 질문, 개념 설명, 예시·연습문제 요청
- **이미지 첨부** — 손으로 푼 문제 사진 등을 올리면 사진 속 수식까지 재구성해 답변 (최대 4장)
- **멀티턴 대화** — 파일별 채팅 히스토리 영구 저장(최근 맥락 유지)
- **사용자 노트 자동 반영** — 그 파일에 작성한 노트(최근 5개)를 컨텍스트로 주입해 개인화
- **마크다운 + 수식(KaTeX)** 렌더링

**동작:**
- 일반 응답(`POST /tutor/messages`)과 **SSE 스트리밍**(`/tutor/messages/stream`) 지원 — 점진적 렌더링으로 체감 지연 절반
- 모델: GPT-4o-mini (비전), 응답 토큰 한도 2500
- 답변이 코드펜스로 감싸져 원본 마크다운이 노출되던 문제는 수정 완료
- 채팅 히스토리 전체 삭제 가능 (`DELETE /tutor/messages`)

---

## 15. 할 일 자동 생성 규칙

강의계획서 파싱(또는 일정 생성/수정) 시, 시험·과제 일정마다 단계별 할 일이 자동 생성됩니다.

| 일정 유형 | 자동 생성되는 할 일 (마감 N일 전 · 우선순위) |
|---|---|
| **시험(exam)** | D-14 (낮음) · D-7 (보통) · D-3 (높음) · D-1 (높음) — 복습 |
| **과제(assignment)** | D-7 (보통) · D-3 (높음) · D-1 (높음) — 작업 |

> 예) 중간고사 6/22 → 6/8·6/15·6/19·6/21 복습 할 일 4개 자동 생성

**규칙:**
- 자동 할 일은 `is_auto=true`로 표시
- 일정 수정/삭제 시 연결된 자동 할 일은 **전체 재생성**, 사용자가 만든 수동 할 일은 링크만 끊김(FK SET NULL)

---

## 16. 푸시 알림

**APNs(Apple Push Notification service)** 기반.

- **디바이스 등록** (`POST /v1/devices/register`) — 앱이 APNs 토큰 등록(upsert), 무효 토큰 자동 정리
- **D-Day 알림** — 매일 **09:00 KST**(Celery Beat) 24시간 내 마감 일정/할 일 리마인드
- **분류 완료 알림** — 강의자료 자동 분류가 끝나면 알림
- **Placeholder 모드** — APNs 키 미설정 시 로그만 남기고 실제 발송은 키 설정 후 활성화

---

## 17. 관리자 기능

`ADMIN_EMAILS` 화이트리스트에 포함된 계정만 접근 (권한 없으면 **404**로 존재 자체 은닉).

**관리자 화면 (`GwaTopAdminView`) 섹션:**
- **개요** — 전체 통계(사용자/학기/과목/파일/일정/할 일/디바이스 수) + 파일 상태 분포
- **사용자** — 사용자 목록 + 개별 사용자의 전체 데이터 트리(학기→과목→파일/일정/할 일)
- **파일** — 전체 파일 목록(처리 상태·분류 결과 포함)
- **일정 / 할 일** — 전체 목록

**데이터 리셋(운영/데모용):**
- 파일 단건 삭제 (강의계획서면 연결된 자동 일정·할 일도 정리)
- **강의계획서 리셋** — 강의계획서·자동 일정/할 일만 정리(학기/과목/수동 데이터 유지)
- **전체 리셋** — 모든 파일·일정·할 일 삭제(User/학기/과목은 유지)

---

## 18. 데이터 모델

전체 계층: **User → Semester → Course → (File / Schedule / Todo)**, File 하위에 학습 데이터.

```
User (사용자)
├─ Semester (학기, is_active로 현재 학기 1개)
│   └─ Course (과목: 이름·교수·색상·강의실·시간표·주차토픽·임베딩캐시)
│       ├─ File (강의자료/계획서)
│       │   ├─ AIContent   (summary/quiz/flashcard/mindmap/memorize/topics/analysis × scope)
│       │   ├─ UserNote     (텍스트/손글씨 노트)
│       │   ├─ TutorMessage (AI 튜터 대화 히스토리)
│       │   └─ UserFlashcardStatus (카드별 known/unknown)
│       ├─ Schedule (일정: lecture/assignment/exam/meeting/upload/custom, is_auto)
│       └─ Todo     (할 일: priority low/medium/high, is_auto, schedule 연결)
└─ Device (APNs 토큰)
```

### 18.1 주요 테이블 (9+ 테이블)

| 테이블 | 저장 내용 | 핵심 컬럼 |
|---|---|---|
| `users` | 계정 | email, hashed_password, name, provider(email/google/apple), school, student_id |
| `semesters` | 학기 | name, start_date, end_date, **is_active** |
| `courses` | 과목 | name, professor, color, location, schedule, **weekly_topics**, **weekly_topic_embeddings** |
| `files` (lecture_files) | 파일 | filename, file_type, s3_key, **status**, **week**, **is_syllabus**, **classification_source**, extracted_text, ai_confidence |
| `schedules` (events) | 일정 | title, **type**, due_date, **is_auto** |
| `todos` | 할 일 | title, due_date, **priority**, is_done, **is_auto**, schedule_id |
| `ai_contents` | AI 콘텐츠 | **content_type**, **scope**, content(JSON) |
| `user_notes` | 사용자 노트 | title, body |
| `tutor_messages` | 튜터 대화 | role(user/assistant), body, tokens |
| `user_flashcard_status` | 카드 학습 | card_front, status(known/unknown), scope |
| `devices` | 디바이스 | apns_token, platform, last_seen_at |

### 18.2 핵심 Enum 값

| 컬럼 | 가능한 값 |
|---|---|
| `users.provider` | email · google · apple |
| `files.status` | pending · uploading · processing · extracted · parsing · parsed · classifying · classified · unclassified · failed |
| `files.classification_source` | filename · embedding · manual · (auto_*) · null |
| `files.file_type` | pdf · pptx · docx · image · other |
| `schedules.type` | lecture · assignment · exam · meeting · upload · custom |
| `todos.priority` | low · medium · high |
| `ai_contents.content_type` | summary · quiz · flashcard · mindmap · memorize · topics · analysis |
| `ai_contents.scope` | all · "1-3" · "5" 등 (페이지 범위) |
| `tutor_messages.role` | user · assistant |
| `user_flashcard_status.status` | known · unknown |

> **파일 상태 판정**: 완료=`classified`/`unclassified`/`parsed`, 실패=`failed`. iOS는 `GwaTopFileService`의 상태 enum으로 배지/폴링을 제어합니다.

---

## 19. 백엔드 API 레퍼런스

모든 경로 prefix `/v1`, 별도 표기 없으면 **JWT 인증 필요**. 소유권은 `user→semester→course→리소스` 조인으로 검증(미소유 시 404, IDOR 방지).

### 인증 `/auth`
| 메서드 · 경로 | 설명 |
|---|---|
| POST `/register` | 이메일 회원가입 (토큰 발급) · 인증 불필요 |
| POST `/login` | 이메일 로그인 · 인증 불필요 |
| POST `/social` | Google 로그인 · 인증 불필요 |
| GET `/me` · PATCH `/me` | 프로필 조회/수정 |
| POST `/me/password` | 비밀번호 변경 |
| POST `/refresh` | Access 토큰 갱신 · 인증 불필요 |

### 학기 `/semesters`
GET `/` · POST `/` · GET/PUT/DELETE `/{id}` · PATCH `/{id}/set-active`

### 과목 `/courses`, `/semesters/{id}/courses`
GET `/courses` · GET/POST `/semesters/{id}/courses` · GET/PUT/DELETE `/courses/{id}`

### 파일 `/files`, `/courses/{id}/files`
| 메서드 · 경로 | 설명 |
|---|---|
| POST `/courses/{id}/files/presigned-url` · `/{fid}/confirm` | 과목 지정 자료 업로드 |
| GET `/courses/{id}/files` | 과목 파일 목록 |
| POST `/files/syllabus/presigned-url` · `/{fid}/confirm` | 강의계획서 업로드(과목 자동) |
| POST `/files/auto/presigned-url` · `/{fid}/confirm` · `/batch-confirm` | 무차별 자동 업로드(배치) |
| GET `/files/in-flight-syllabi` | 파싱 진행 중 강의계획서 |
| POST `/files/{id}/reclassify` · PATCH `/files/{id}/week` | 재분류 / 주차 수동 지정 |
| GET `/files/{id}/presigned-download` | PDF 보기용 다운로드 URL(1시간) |

### 학습 `/files/{id}/...`
| 메서드 · 경로 | 설명 |
|---|---|
| GET `/ai-contents/{type}` | 캐시된 AI 콘텐츠 조회 (`?pages=` 지원) |
| POST `/ai-contents/{type}/generate` | 생성 요청(202, `force`/`exclude_questions`) |
| POST `/ai-contents/prefetch` | 5종 콘텐츠 선생성 |
| GET/PUT `/flashcards/status` · POST `/flashcards/more` | 카드 상태 / 카드 추가 |
| GET/POST/PATCH/DELETE `/notes` | 노트 CRUD |
| GET/POST `/tutor/messages` · `/stream` · DELETE | 튜터 질문/스트리밍/히스토리 삭제 |

### 일정 `/schedules`
GET `/` (start/end/course_id 필터) · GET `/calendar/summary` · POST `/` · PUT/DELETE `/{id}`

### 할 일 `/todos`
GET `/` (다중 필터) · POST `/` · PATCH/DELETE `/{id}`

### 홈 `/home`
GET `/dashboard` — 오늘 일정 + 급한 할 일 + 주간 요약 + 다음 일정 (단일 호출)

### 디바이스 `/devices`
POST `/register` · DELETE `/{apns_token}`

### 관리자 `/admin` (화이트리스트)
GET `/overview` · `/users` · `/users/{id}` · `/files` · `/schedules` · `/todos`
DELETE `/files/{id}` · POST `/users/{id}/syllabus-reset` · `/users/{id}/full-reset`

> 전체 스키마: `gwatop-backend/gwatop_openapi.yaml`

---

## 20. 기술 스택 · 인프라

### 백엔드 처리·안정화
- **Celery 비동기 워커** (Redis 브로커/결과 백엔드) — 모든 AI 작업 백그라운드 처리
- **워커 내구성** — soft/hard 타임리밋(180s/300s), child 재활용(80 tasks / 300MB), `acks_late`+재배달, **워치독 타이머**(90초 주기, 부팅유예+ping 3회+큐적체 게이트로 오탐 방지)
- **성능 최적화** — 강의계획서 표 선추출(지연 50%↓), analysis 재사용(입력 토큰 ↓), 임베딩 캐시 재사용, OCR 페이지 병렬, 요약·분류 병렬화

### iOS 최적화
- **URLCache 확대**(32MB/200MB) + 백엔드 `Cache-Control`로 AI 콘텐츠 캐시 hit 시 네트워크 0회
- **로그인 직후 warmup()** — 핵심 데이터 병렬 선로드
- **PDF 디스크 캐시**, **silent reload**, **강의계획서 워처**로 백그라운드 진행 추적

### 운영 (EC2)
- EC2 Ubuntu + **Caddy**(Let's Encrypt 자동 TLS, `:443 → localhost:8000`)
- systemd 유닛: `gwatop-uvicorn`, `gwatop-celery`(둘 다 `Restart=always`), `gwatop-celery-watchdog.timer`
- PostgreSQL은 **AWS RDS**, Redis 로컬, 배포 브랜치는 `dev`

---

## 21. 웹 버전 (gwatop-web)

iOS 앱과 **기능 패리티**를 목표로 하는 웹 클라이언트 (별도 레포 `mj-nuhylabs/gwatop-web`).

- **스택**: Next.js 16 (App Router) + Turbopack, React 19
- **배포**: AWS Amplify (main push → 자동 빌드), 도메인 `app.gwatop.co.kr`
- **API**: 동일한 백엔드 `https://api.gwatop.co.kr` 사용 (`NEXT_PUBLIC_API_BASE`)
- **PDF 미리보기**: `pdfjs-dist` self-host (cmaps 포함, 한글 글리프 정상 렌더)
- **AI 기능**: 요약/퀴즈/플래시카드/마인드맵/암기/핵심개념 + AI 튜터를 iOS와 동일하게 제공(패리티 진행 — `docs/turbo-ai-parity-plan.md` 참고)

---

## 부록: 용어 정리

| 용어 | 의미 |
|---|---|
| **강의계획서 (Syllabus)** | 학기 초 받는 과목 개요 PDF — 파싱 시 과목·시간표·일정·할 일 자동 생성 |
| **강의자료 (Material)** | 학기 중 받는 수업 PDF — 과목·주차 자동 분류 + AI 학습 콘텐츠 생성 |
| **무차별 업로드** | 종류·과목·주차를 안 고르고 던지면 AI가 알아서 분류하는 업로드 |
| **scope** | AI 콘텐츠의 페이지 범위 식별자 (`all` 또는 `1-3` 등) |
| **is_auto** | 강의계획서 파싱이 자동 생성한 일정/할 일 표시 플래그 |
| **classification_source** | 주차 분류 근거 (파일명/임베딩/수동) |

---

*이 문서는 코드베이스(`GwaTop` iOS + `gwatop-backend` FastAPI) 전수 조사를 바탕으로 작성되었습니다. 구현 변경 시 함께 갱신해 주세요.*
