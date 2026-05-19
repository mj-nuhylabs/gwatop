from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from app.api.v1.routes.auth import router as auth_router

app = FastAPI(title="GwaTop API", version="1.0.0")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

app.include_router(auth_router, prefix="/v1")

@app.get("/health")
async def health():
    return {"status": "ok"}
