from pydantic_settings import BaseSettings, SettingsConfigDict
from pydantic import field_validator


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", case_sensitive=False, extra="ignore")

    # --- 운영 플래그 ---
    # DEBUG=True 일 때만 디버그 전용 엔드포인트(/files/{id}/debug 등) 노출.
    DEBUG: bool = False
    # CORS 허용 origin. 콤마 구분 문자열. "*" 면 와일드카드 (Bearer 토큰 API에는 비권장).
    # 예: "https://app.gwatop.com,http://localhost:3000"
    ALLOWED_ORIGINS: str = "*"

    # --- 업로드 정책 ---
    # presigned URL 발급 시 허용할 최대 파일 크기(바이트). 기본 50MB.
    MAX_UPLOAD_BYTES: int = 50 * 1024 * 1024
    # 허용 file_type (앱 화이트리스트와 일치해야 함).
    # pdf(PyMuPDF) / pptx(python-pptx) / docx(python-docx) / image(GPT-4o-mini vision OCR)
    # 추출기를 모두 갖췄다. image 는 임베드 텍스트가 없어 항상 OCR 로 텍스트를 뽑는다
    # (app/tasks/file_tasks.py 의 _extract_text_into image 분기 → ocr_fallback.ocr_image).
    # 유튜브 링크는 별도 resource_type 흐름(후속)으로 처리한다.
    ALLOWED_FILE_TYPES: str = "pdf,pptx,docx,image"

    # 유튜브 자막 추출용 선택적 프록시. EC2 IP 가 YouTube 에 차단될 때 .env 에
    # 프록시 URL(예: "http://user:pass@host:port")을 넣으면 youtube_extractor 가 우회한다.
    # 비어 있으면 직접 요청(데모/소량엔 충분, 대량/연속 요청 시 차단 가능).
    YOUTUBE_PROXY_URL: str = ""

    # --- 관리자 (출시 전 테스트용) ---
    # 이 이메일 목록의 사용자만 /v1/admin/* 엔드포인트 접근 가능. 콤마 구분.
    # 예: "hyunnow28@gmail.com,admin@gwatop.com"
    ADMIN_EMAILS: str = ""

    DATABASE_URL: str
    REDIS_URL: str
    SECRET_KEY: str
    ALGORITHM: str = "HS256"
    ACCESS_TOKEN_EXPIRE_MINUTES: int = 60
    REFRESH_TOKEN_EXPIRE_DAYS: int = 30
    AWS_ACCESS_KEY_ID: str
    AWS_SECRET_ACCESS_KEY: str
    AWS_REGION: str = "ap-northeast-2"
    S3_BUCKET_NAME: str

    @property
    def allowed_origins_list(self) -> list[str]:
        raw = self.ALLOWED_ORIGINS.strip()
        if raw == "*":
            return ["*"]
        return [o.strip() for o in raw.split(",") if o.strip()]

    @property
    def allowed_file_types_set(self) -> set[str]:
        return {t.strip().lower() for t in self.ALLOWED_FILE_TYPES.split(",") if t.strip()}

    @property
    def admin_emails_set(self) -> set[str]:
        return {e.strip().lower() for e in self.ADMIN_EMAILS.split(",") if e.strip()}

    # Google OAuth Client ID. iOS / 웹 / 안드로이드 각각 별도라 콤마 구분 multi 값 지원.
    # 예: "ios_id.apps.googleusercontent.com,web_id.apps.googleusercontent.com"
    GOOGLE_CLIENT_ID: str = (
        "166115611136-d42e728kfojf7resv9um0fcpgeffo8lp.apps.googleusercontent.com,"
        "166115611136-8tcfd6o12s9a2bn0u2hfeko5d0k2a4k5.apps.googleusercontent.com"
    )

    @property
    def google_client_ids_set(self) -> set[str]:
        raw = (self.GOOGLE_CLIENT_ID or "").strip()
        if not raw:
            return set()
        return {c.strip() for c in raw.split(",") if c.strip()}
    OPENAI_API_KEY: str = ""
    # OpenAI 호출당 타임아웃(초) + 재시도. SDK 기본은 600초라 네트워크가 멈추면 한 호출이
    # 수 분간 매달려 배치 업로드가 통째로 지연된다. 90초로 잘라 '가끔 3분씩 걸림'을 방지.
    # (정상 호출은 길어야 40초라 여유. 일시 실패는 재시도로 흡수.)
    OPENAI_REQUEST_TIMEOUT: float = 90.0
    OPENAI_MAX_RETRIES: int = 2
    # 강의계획서 파싱 모델. 속도 우선이면 gpt-4.1-nano (빠르지만 약간 떨어질 수 있음),
    # 정확도/안정성 우선이면 gpt-4o-mini (현재 기본). 둘 다 JSON mode 지원.
    # EC2 .env 에 OPENAI_SYLLABUS_MODEL=gpt-4.1-nano 로 변경 후 워커 재시작하면 즉시 적용.
    OPENAI_SYLLABUS_MODEL: str = "gpt-4o-mini"
    OPENAI_SYLLABUS_TEMPERATURE: float = 0.1
    OPENAI_SYLLABUS_MAX_TOKENS: int = 4096
    # 강의계획서 파싱을 course-meta / weeks+events 두 호출로 분할하여 asyncio.gather 로 병렬 실행.
    # 출력 토큰이 분산되어 latency 30-40% 감소. 정확도 회귀 가능성이 있어 기본 OFF.
    SYLLABUS_PARSE_PARALLEL: bool = False
    # 동일 (extracted_text, year, term) 조합 재파싱 시 Redis 캐시 사용. 재업로드/디버그 시 0초.
    SYLLABUS_CACHE_ENABLED: bool = True
    # PyMuPDF find_tables() 로 주차표를 직접 추출. 성공하면 weeks 부분 LLM 호출을 생략하여
    # latency 50% 가까이 감소. 표가 깔끔하지 않은 PDF 는 자동으로 LLM 단일 호출로 fallback.
    # 정확도 회귀 위험 보수적 처리 — EC2 .env 에서 활성화한다.
    SYLLABUS_TABLE_EXTRACTION_ENABLED: bool = False
    # PDF 추출을 PyMuPDF raw 텍스트 → pymupdf4llm 구조보존 마크다운으로 전환.
    # 제목/리스트/표 위계가 살아 요약·퀴즈·강의계획서 파싱 품질↑. 페이지 슬라이싱(\f)은
    # 그대로 호환. **옵셔널 의존성** — 켜기 전 `pip install pymupdf4llm` 필요
    # (미설치/변환실패 시 자동 raw 텍스트 폴백이라 추출 자체는 안 깨짐).
    # 추출 포맷이 바뀌어 분류 임베딩·슬라이싱에 영향 줄 수 있어 기본 OFF — 스테이징 검증 후 ON.
    PDF_MARKDOWN_EXTRACTION: bool = False

    # --- AI 요약 노트 / 학습 콘텐츠 ---
    # 기본은 gpt-4.1-nano — gpt-4o-mini 대비 ~2x 빠름, 품질도 학습 콘텐츠엔 충분.
    # 품질 우선이면 .env 에서 OPENAI_SUMMARY_MODEL=gpt-4o-mini 또는 gpt-4o 로 교체.
    OPENAI_SUMMARY_MODEL: str = "gpt-4.1-nano"
    # 마인드맵·퀴즈는 응답이 길어 1200 으론 잘리는 경우 발생.
    # 4000 정도면 nano/mini 모두 안전 마진. 비용은 사용한 만큼만 청구되므로 상한만 큼.
    OPENAI_SUMMARY_MAX_TOKENS: int = 4000
    # Structured Outputs(strict json_schema) 사용 — 모델이 스키마를 100% 준수해
    # "유효한 퀴즈/카드/마인드맵 없음" 류 생성 실패가 급감한다. (요약/분석/퀴즈/플래시카드/
    # 마인드맵/암기/주요개념 7종에 적용.) 미지원 모델·스키마 거부 시 자동으로 기존
    # json_object 모드로 폴백(서킷 브레이커)하므로 최악도 "오늘과 동일 동작"이다.
    # 문제 발생 시 EC2 .env 에 OPENAI_STRUCTURED_OUTPUTS=false 로 즉시 롤백 가능.
    OPENAI_STRUCTURED_OUTPUTS: bool = True

    # --- AI 튜터 (멀티모달 채팅) ---
    # 튜터는 사진 첨부(vision) 와 길고 정제된 마크다운+LaTeX 응답이 필요해서
    # 요약/콘텐츠 생성과 다른 모델을 별도 지정한다. 4o-mini 는 vision 입력 + 200K context
    # 지원하면서도 nano 대비 비용 차이가 미미.
    OPENAI_TUTOR_MODEL: str = "gpt-4o-mini"
    # 응답 토큰 상한. 한 번에 인덱스/예시/연습 문제까지 풍부하게 받을 수 있도록 2500 으로 확대.
    # (기존 900 은 공식이 절반에서 잘려 사용자가 "성의 없다" 느꼈음.)
    OPENAI_TUTOR_MAX_TOKENS: int = 2500
    # 튜터 답변의 창의성. 0.3~0.5 권장 — 정확성 + 약간의 친근함.
    OPENAI_TUTOR_TEMPERATURE: float = 0.35

    # --- Day 4: 강의 자료 자동 분류 ---
    OPENAI_EMBEDDING_MODEL: str = "text-embedding-3-small"
    # 파일명 regex 매칭 시 이 confidence를 부여한다. 강의계획서 weeks와 무관하게 신뢰.
    CLASSIFY_FILENAME_CONFIDENCE: float = 0.92
    # 임베딩 코사인 유사도가 이 값 이상이어야 주차 배정. 미만이면 unclassified.
    CLASSIFY_EMBEDDING_FLOOR: float = 0.30
    # 임베딩 비교에 사용할 파일 텍스트 앞부분 길이(자).
    CLASSIFY_EMBEDDING_INPUT_CHARS: int = 4000

    # --- 문서 분류 (추출신호 + doc_type 1회 통합 호출) ---
    # 빠른 모델 우선 → 저신뢰 시 큰 모델로 1회만 승급. 대부분 파일은 빠른 모델 1회로 끝난다.
    CLASSIFY_FAST_MODEL: str = "gpt-4.1-nano"
    CLASSIFY_ESCALATE_MODEL: str = "gpt-4o-mini"
    # 이 confidence 미만이거나 doc_type=='불확실' 이면 큰 모델로 1회 재시도.
    CLASSIFY_CONFIDENCE_THRESHOLD: float = 0.70
    # 승급 후에도 이 confidence 미만이면 '확인 필요'(needs_review)로 두고 자동 결정 보류.
    CLASSIFY_REVIEW_THRESHOLD: float = 0.50
    # 통합 분류 LLM 에 보낼 본문 앞부분 길이(자). 강의계획서 신호(과목정보·평가비율·주차일정)는
    # 보통 앞쪽에 몰려 있어 앞부분만 봐도 충분하고 입력 토큰이 줄어 지연시간이 크게 준다.
    CLASSIFY_DOC_INPUT_CHARS: int = 4000
    # 동일 콘텐츠 재업로드 시 분류 결과 재사용(콘텐츠 해시 dedup). Redis 불가 시 silent miss.
    CLASSIFY_CACHE_ENABLED: bool = True
    CLASSIFY_CACHE_TTL_SECONDS: int = 7 * 24 * 60 * 60
    # 자동 배치 업로드 시 파일별 추출+분류를 동시에 처리하는 최대 개수.
    # 각 파일 분류는 독립적이라 병렬화해도 안전하며, LLM/임베딩 대기를 겹쳐 지연을 줄인다.
    BATCH_INGEST_CONCURRENCY: int = 4

    # --- 과목 매칭 (규칙 우선 → 모호할 때만 LLM) ---
    # 최고 후보가 이 점수 이상이면 규칙만으로 매칭 확정.
    COURSE_MATCH_FUZZY_THRESHOLD: float = 0.70
    # 1위-2위 점수 차가 이 값 미만이면 '모호'로 보고 LLM 디스앰비규에이션을 시도.
    COURSE_MATCH_AMBIGUOUS_MARGIN: float = 0.15
    COURSE_MATCH_LLM_ENABLED: bool = True
    COURSE_MATCH_MODEL: str = "gpt-4.1-nano"

    # --- 변경 탐지 (키워드 게이트 → LLM, 자동반영 금지·승인 후에만 DB 갱신) ---
    CHANGE_DETECTION_ENABLED: bool = True
    CHANGE_DETECTION_MODEL: str = "gpt-4o-mini"
    # 본문에서 변경 관련 부분을 LLM 에 보낼 길이(자).
    CHANGE_DETECTION_INPUT_CHARS: int = 6000
    # 이 confidence 미만 변경 후보는 제안에서 제외.
    CHANGE_DETECTION_MIN_CONFIDENCE: float = 0.55

    # --- 자동 할일(ToDo) 생성 ---
    # 시험 일정에서 'D-14/7/3/1 시험 복습' 자동 할일을 만들지 여부. 기본 OFF —
    # 사용자 피드백상 과제 탭이 복습 리마인더로 지저분해져, 시험 '일정'만 남기고
    # 복습 할일은 만들지 않는다. 다시 켜려면 .env 에 AUTO_EXAM_REVIEW_TODOS=true.
    # (과제 마감 'D-7/3/1 작업' 할일은 실제 마감 리마인더라 이 플래그와 무관하게 유지.)
    AUTO_EXAM_REVIEW_TODOS: bool = False

    # --- Day 7: APNs 푸시 알림 ---
    # 키가 비어 있으면 services/apns.py가 placeholder mode (로그만, 네트워크 호출 없음)로 동작.
    # 4개 모두 채우면 실제 APNs HTTP/2 push 활성화.
    APNS_KEY_ID: str = ""           # AuthKey 파일명에서 추출한 10자 식별자
    APNS_TEAM_ID: str = ""          # Apple Developer Team ID (10자)
    APNS_KEY_PATH: str = ""         # AuthKey_*.p8 파일 절대 경로
    APNS_BUNDLE_ID: str = "com.gwatop.app"  # iOS 앱 Bundle ID
    APNS_PRODUCTION: bool = False   # True면 api.push.apple.com, False면 api.sandbox.push.apple.com

settings = Settings()
