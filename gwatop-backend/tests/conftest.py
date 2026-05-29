"""테스트 공통 설정.

app.core.config.Settings 가 요구하는 필수 env 를 더미 값으로 채운다.
로컬/CI 에 .env·실제 인프라(DB/S3/Redis)가 없어도 순수 로직(토큰 타입,
정규식 분류, 강의계획서 파싱 헬퍼 등)을 import 해서 단위 테스트할 수 있게 한다.
실제 외부 서비스에는 연결하지 않는다.
"""
import os

os.environ.setdefault("SECRET_KEY", "test-secret-key-not-for-production")
os.environ.setdefault("DATABASE_URL", "postgresql+asyncpg://test:test@localhost/test")
os.environ.setdefault("REDIS_URL", "redis://localhost:6379/0")
os.environ.setdefault("AWS_ACCESS_KEY_ID", "test")
os.environ.setdefault("AWS_SECRET_ACCESS_KEY", "test")
os.environ.setdefault("S3_BUCKET_NAME", "test-bucket")
