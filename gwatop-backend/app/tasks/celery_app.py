from celery import Celery
from celery.schedules import crontab

from app.core.config import settings

celery_app = Celery(
    "gwatop",
    broker=settings.REDIS_URL,
    backend=settings.REDIS_URL,
    include=["app.tasks.file_tasks", "app.tasks.notify_tasks"],
)

celery_app.conf.update(
    task_serializer="json",
    result_serializer="json",
    accept_content=["json"],
    timezone="Asia/Seoul",
    enable_utc=True,
    # Day 7: Celery Beat 스케줄
    # 매일 09:00 KST에 D-Day 알림(24h 이내 마감 todos/schedules)을 보낸다.
    beat_schedule={
        "notify-due-dday-daily-9am": {
            "task": "tasks.notify_due_dday",
            "schedule": crontab(hour=9, minute=0),
        },
    },
)
