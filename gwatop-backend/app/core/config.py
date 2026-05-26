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
    ALLOWED_FILE_TYPES: str = "pdf,pptx,docx,image"

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
    GOOGLE_CLIENT_ID: str = "166115611136-d42e728kfojf7resv9um0fcpgeffo8lp.apps.googleusercontent.com"
    OPENAI_API_KEY: str = ""
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

    # --- AI 요약 노트 / 학습 콘텐츠 ---
    # 기본은 gpt-4.1-nano — gpt-4o-mini 대비 ~2x 빠름, 품질도 학습 콘텐츠엔 충분.
    # 품질 우선이면 .env 에서 OPENAI_SUMMARY_MODEL=gpt-4o-mini 또는 gpt-4o 로 교체.
    OPENAI_SUMMARY_MODEL: str = "gpt-4.1-nano"
    # 마인드맵·퀴즈는 응답이 길어 1200 으론 잘리는 경우 발생.
    OPENAI_SUMMARY_MAX_TOKENS: int = 2500

    # --- Day 4: 강의 자료 자동 분류 ---
    OPENAI_EMBEDDING_MODEL: str = "text-embedding-3-small"
    # 파일명 regex 매칭 시 이 confidence를 부여한다. 강의계획서 weeks와 무관하게 신뢰.
    CLASSIFY_FILENAME_CONFIDENCE: float = 0.92
    # 임베딩 코사인 유사도가 이 값 이상이어야 주차 배정. 미만이면 unclassified.
    CLASSIFY_EMBEDDING_FLOOR: float = 0.30
    # 임베딩 비교에 사용할 파일 텍스트 앞부분 길이(자).
    CLASSIFY_EMBEDDING_INPUT_CHARS: int = 4000

    # --- Day 7: APNs 푸시 알림 ---
    # 키가 비어 있으면 services/apns.py가 placeholder mode (로그만, 네트워크 호출 없음)로 동작.
    # 4개 모두 채우면 실제 APNs HTTP/2 push 활성화.
    APNS_KEY_ID: str = ""           # AuthKey 파일명에서 추출한 10자 식별자
    APNS_TEAM_ID: str = ""          # Apple Developer Team ID (10자)
    APNS_KEY_PATH: str = ""         # AuthKey_*.p8 파일 절대 경로
    APNS_BUNDLE_ID: str = "com.gwatop.app"  # iOS 앱 Bundle ID
    APNS_PRODUCTION: bool = False   # True면 api.push.apple.com, False면 api.sandbox.push.apple.com

settings = Settings()
