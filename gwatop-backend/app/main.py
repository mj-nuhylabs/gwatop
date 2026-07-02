from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

import app.models  # noqa: F401 — register all ORM models before first query
from app.api.v1.routes.auth import router as auth_router
from app.api.v1.routes.semesters import router as semesters_router
from app.api.v1.routes.courses import router as courses_router
from app.api.v1.routes.files import router as files_router
from app.api.v1.routes.schedules import router as schedules_router
from app.api.v1.routes.todos import router as todos_router
from app.api.v1.routes.home import router as home_router
from app.api.v1.routes.devices import router as devices_router
from app.api.v1.routes.admin import router as admin_router
from app.api.v1.routes.study import router as study_router
from app.api.v1.routes.update_proposals import router as update_proposals_router
from app.api.v1.routes.billing import router as billing_router
from app.core.config import settings

app = FastAPI(title="GwaTop API", version="1.0.0", docs_url="/docs", redoc_url="/redoc")

# CORS: 와일드카드를 쓰면 allow_credentials=False가 강제됨. 운영에서는
# settings.ALLOWED_ORIGINS 에 도메인 화이트리스트를 명시해야 한다.
_origins = settings.allowed_origins_list
_allow_credentials = _origins != ["*"]
app.add_middleware(
    CORSMiddleware,
    allow_origins=_origins,
    allow_credentials=_allow_credentials,
    allow_methods=["*"],
    allow_headers=["*"],
)

app.include_router(auth_router, prefix="/v1")
app.include_router(semesters_router, prefix="/v1")
app.include_router(courses_router, prefix="/v1")
# study_router 는 files_router 의 GET /ai-contents/{type} 와 path 가 겹친다.
# FastAPI 는 먼저 등록된 라우트가 우선하므로, scope(pages) 쿼리를 지원하는
# study_router 를 files_router 보다 *먼저* 등록해야 한다. (이 순서가 어긋나면
# files_router 의 비-scope 핸들러가 가로채 pages 쿼리가 조용히 무시된다.)
app.include_router(study_router, prefix="/v1")
app.include_router(files_router, prefix="/v1")
app.include_router(schedules_router, prefix="/v1")
app.include_router(todos_router, prefix="/v1")
app.include_router(home_router, prefix="/v1")
app.include_router(devices_router, prefix="/v1")
app.include_router(admin_router, prefix="/v1")
app.include_router(update_proposals_router, prefix="/v1")
app.include_router(billing_router, prefix="/v1")


@app.get("/health")
async def health():
    return {"status": "ok"}
