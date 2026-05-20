from pydantic_settings import BaseSettings, SettingsConfigDict

class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", case_sensitive=False, extra="ignore")

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

settings = Settings()
