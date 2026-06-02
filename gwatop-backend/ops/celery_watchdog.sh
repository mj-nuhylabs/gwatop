#!/usr/bin/env bash
# GwaTop Celery 워치독
# ---------------------------------------------------------------------------
# 목적: 워커가 "프로세스는 살아있지만 응답 없음(wedged)" 상태일 때 자동 재시작.
#
#   systemd 의 Restart=always 는 '프로세스 死'만 복구한다. 그러나 모든 prefork
#   child 가 hang(예: 외부 호출 무한대기, 잔여 async 상태)으로 점유되면 메인
#   프로세스는 살아있어 Restart 가 발동하지 않고, 큐만 쌓인다. 이 스크립트는
#   `celery inspect ping` 무응답을 직접 감지해 그 사각지대를 메운다.
#
# 실행: gwatop-celery-watchdog.timer 가 주기 호출(root). 수동 점검도 가능.
# 종료코드는 항상 0 — timer 가 실패로 표시되지 않게 한다(워치독 자체는 best-effort).
# ---------------------------------------------------------------------------
set -uo pipefail

APP_DIR="/home/ubuntu/gwatop/gwatop-backend"
cd "$APP_DIR" || exit 0

# 브로커(REDIS_URL) 등 환경 로드 — systemd EnvironmentFile 로도 들어오지만
# 수동 실행/안전을 위해 한 번 더 source (단순 KEY=VALUE 형식).
set -a; . "$APP_DIR/.env" 2>/dev/null || true; set +a

PING() { timeout 30 "$APP_DIR/.venv/bin/celery" -A app.tasks.celery_app inspect ping 2>/dev/null | grep -q pong; }

# 1회 무응답은 일시적 부하(전 child 가 짧게 바쁨)일 수 있으니 2회 연속일 때만 조치.
if PING; then exit 0; fi
sleep 7
if PING; then exit 0; fi

logger -t gwatop-celery-watchdog "celery 워커 ping 무응답(2회 연속) — gwatop-celery 재시작"
systemctl restart gwatop-celery || true
exit 0
