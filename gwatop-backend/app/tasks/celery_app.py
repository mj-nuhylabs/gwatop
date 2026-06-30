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
    # 결과를 읽는 곳이 없으므로(.get() 미사용, 전부 fire-and-forget) 결과 백엔드 쓰기를 끈다.
    # → 태스크마다 Redis 결과행 기록이 사라져 브로커 왕복/메모리 부담 감소.
    task_ignore_result=True,
    # ===== 안정성 하드닝 (워커 멈춤/죽음 방지·대비) =====
    # 배경: 타임리밋이 없으면 멈춘(혹은 폭주한) 태스크가 prefork child 를 영구 점유하고,
    #       메모리가 불어나 OOM SIGKILL → WorkerLostError 로 이어진다(2026-05-27 18분
    #       hang 후 SIGKILL 실측). concurrency=2 라 child 2개만 묶여도 큐가 안 빠진다.
    #
    # 1) 멈춘 태스크를 강제 종료 — child 영구 점유 차단.
    #    soft: 잡을 수 있는 예외(정상 실패 처리 기회) / hard: child 강제 kill 후 자동 교체.
    #    정상 작업은 길어야 ~15초(LLM·OCR 포함 여유). 180/300 은 진짜 hang 만 자른다.
    task_soft_time_limit=180,
    task_time_limit=300,
    # 2) child 주기적 재활용 — PyMuPDF/임베딩 네이티브 누수 + async 잔여상태 청소.
    worker_max_tasks_per_child=80,
    worker_max_memory_per_child=300_000,   # KB(≈293MB) 초과 시 작업 사이에 child 교체
    # 3) child 가 SIGKILL(OOM 등)로 죽어도 그 태스크를 잃지 않고 재배달.
    #    (태스크들은 캐시/유니크 제약/상태 멱등이라 재실행 안전. 단 native segfault 가
    #     결정적이면 재배달 루프 가능 — 위 메모리/타임리밋으로 그 확률을 먼저 낮춘다.)
    task_acks_late=True,
    task_reject_on_worker_lost=True,
    # 4) child 당 선점 태스크 1개 — 한쪽 child 에 쏠려 다른 작업이 굶는 것 방지.
    worker_prefetch_multiplier=1,
    # 5) 부팅 시 브로커(Redis) 연결 재시도 (Celery 5 권장 기본값).
    broker_connection_retry_on_startup=True,
    # ===== 작업 우선순위 (Redis 단일 큐 내 priority) =====
    # 배경: 파일 학습 화면 진입 시 prefetch 가 5종 콘텐츠를 '투기적으로' 큐잉한다.
    #       concurrency 가 작을 때(현재 2) 이 5개가 큐를 채우면, 정작 중요한 실작업
    #       (텍스트 추출/분류/강의계획서 파싱/요약/사용자가 직접 누른 생성)이 뒤로 밀린다.
    # 해결: Redis transport 의 priority 를 켜고 prefetch 만 낮은 우선순위로 보낸다.
    #       Redis 규칙상 **숫자가 작을수록 먼저 소비**(0=최우선, 9=최후순위).
    #       단일 'celery' 큐 안에서 동작하므로 워커 -Q 옵션/별도 큐가 필요 없다 — 워커
    #       재시작만으로 적용. (worker_prefetch_multiplier=1 이 위에 있어 priority 가 실효.)
    # 안전: 미지원/오설정이어도 최악은 "전부 동일 우선순위 = 오늘과 같은 FIFO" — 순수 상향.
    task_queue_max_priority=9,
    task_default_priority=5,        # 일반 작업 기본(중간). prefetch(9)보다 항상 먼저 처리됨.
    broker_transport_options={
        "priority_steps": list(range(10)),
        "sep": ":",
        "queue_order_strategy": "priority",
    },
    # Day 7: Celery Beat 스케줄
    # 매일 09:00 KST에 D-Day 알림(24h 이내 마감 todos/schedules)을 보낸다.
    beat_schedule={
        "notify-due-dday-daily-9am": {
            "task": "tasks.notify_due_dday",
            "schedule": crontab(hour=9, minute=0),
        },
    },
)
