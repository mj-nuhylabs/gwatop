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
    GOOGLE_CLIENT_ID: str = "166115611136-d42e728kfojf7resv9um0fcpgeffo8lp.apps.googleusercontent.com"
    OPENAI_API_KEY: str = ""
    OPENAI_SYLLABUS_MODEL: str = "gpt-4o-mini"
    OPENAI_SYLLABUS_TEMPERATURE: float = 0.1
    OPENAI_SYLLABUS_MAX_TOKENS: int = 4096

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
