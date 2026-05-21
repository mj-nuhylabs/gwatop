from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

import app.models  # noqa: F401 — register all ORM models before first query
from app.api.v1.routes.auth import router as auth_router
from app.api.v1.routes.semesters import router as semesters_router
from app.api.v1.routes.courses import router as courses_router
from app.api.v1.routes.files import router as files_router
from app.api.v1.routes.schedules import router as schedules_router
from app.api.v1.routes.todos import router as todos_router

app = FastAPI(title="GwaTop API", version="1.0.0", docs_url="/docs", redoc_url="/redoc")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

app.include_router(auth_router, prefix="/v1")
app.include_router(semesters_router, prefix="/v1")
app.include_router(courses_router, prefix="/v1")
app.include_router(files_router, prefix="/v1")
app.include_router(schedules_router, prefix="/v1")
app.include_router(todos_router, prefix="/v1")


@app.get("/health")
async def health():
    return {"status": "ok"}
