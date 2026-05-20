from sqlalchemy.ext.asyncio import create_async_engine, AsyncSession
from sqlalchemy.orm import sessionmaker, DeclarativeBase
from sqlalchemy.pool import NullPool
from app.core.config import settings

# ----- FastAPI 요청용 (장수명 풀, 단일 이벤트루프) -----
engine = create_async_engine(
    settings.DATABASE_URL,
    echo=False,
    pool_pre_ping=True,
    connect_args={"timeout": 5},
    pool_timeout=8,
    pool_recycle=300,
)
AsyncSessionLocal = sessionmaker(engine, class_=AsyncSession, expire_on_commit=False)


class Base(DeclarativeBase):
    pass


async def get_db():
    async with AsyncSessionLocal() as session:
        try:
            yield session
            await session.commit()
        except Exception:
            await session.rollback()
            raise


# ----- Celery 태스크용 (매 호출마다 새 connection, NullPool로 풀 안 함) -----
# Celery + async SQLAlchemy는 asyncio.run()이 호출마다 새 이벤트루프를 만들기 때문에,
# 풀에 잡혀있는 connection이 이전 루프에 bind되어 있어 "attached to a different loop"
# 에러가 나기 쉽다. NullPool로 풀링을 끄면 connection이 사용 후 즉시 닫혀 문제 없음.
def make_celery_session_factory():
    celery_engine = create_async_engine(
        settings.DATABASE_URL,
        echo=False,
        poolclass=NullPool,
        connect_args={"timeout": 5},
    )
    return celery_engine, sessionmaker(celery_engine, class_=AsyncSession, expire_on_commit=False)
