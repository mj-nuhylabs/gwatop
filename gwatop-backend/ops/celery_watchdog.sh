#!/usr/bin/env bash
# GwaTop Celery 워치독
# ---------------------------------------------------------------------------
# 목적: 워커가 "프로세스는 살아있지만 응답 없음(wedged)" 상태일 때만 자동 재시작.
#
#   systemd 의 Restart=always 는 '프로세스 死'만 복구한다. 그러나 모든 prefork
#   child 가 hang 으로 점유되면 메인 프로세스는 살아있어 Restart 가 발동하지 않고
#   큐만 쌓인다. 이 스크립트는 그 사각지대를 메운다.
#
# 설계 원칙 — 데모 중 "멀쩡한 워커를 죽이는 오탐"이 진짜 다운보다 위험하므로 보수적:
#   1) celery 가 최근 90초 내 (재)기동됐으면 워밍업 중 → 건드리지 않는다.
#   2) ping 내부 타임아웃 10초로 넉넉히 + 3회 연속 무응답일 때만 의심한다.
#   3) 그래도 "큐에 일이 쌓였는데(=처리돼야 할 작업) 안 빠지는" 경우에만 재시작한다.
#      놀고 있는(큐 0) 워커가 ping 한 번 늦었다고 재시작하지 않는다. 멈춘 단일
#      태스크는 task_time_limit(300s) 가 따로 끊어준다.
#
# 실행: gwatop-celery-watchdog.timer 가 90초마다 호출(root). 종료코드는 항상 0.
# ---------------------------------------------------------------------------
set -uo pipefail

APP_DIR="/home/ubuntu/gwatop/gwatop-backend"
cd "$APP_DIR" || exit 0
set -a; . "$APP_DIR/.env" 2>/dev/null || true; set +a

CELERY="$APP_DIR/.venv/bin/celery -A app.tasks.celery_app"
REDIS="${REDIS_URL:-redis://localhost:6379/0}"

# --- 1) 부팅 유예: 최근 90초 내 기동이면 워밍업 중일 수 있으니 skip ---
active_since=$(systemctl show gwatop-celery -p ActiveEnterTimestampMonotonic --value 2>/dev/null || echo 0)
now_mono=$(awk '{printf "%d", $1*1000000}' /proc/uptime)
age=$(( (now_mono - ${active_since:-0}) / 1000000 ))
if [ "${active_since:-0}" -gt 0 ] && [ "$age" -lt 90 ]; then
    exit 0
fi

ping_ok() { timeout 20 $CELERY inspect ping -t 10 2>/dev/null | grep -q pong; }
qlen()    { redis-cli -u "$REDIS" llen celery 2>/dev/null || echo 0; }

# --- 2) 3회 연속 무응답 확인 (한 번이라도 pong 이면 정상) ---
q_start=$(qlen)
for _ in 1 2 3; do
    if ping_ok; then exit 0; fi
    sleep 8
done

# --- 3) 큐 적체 게이트: 일이 쌓였고(>0) 그동안 안 빠졌으면(wedged) 재시작 ---
q_end=$(qlen)
if [ "${q_end:-0}" -gt 0 ] && [ "${q_end:-0}" -ge "${q_start:-0}" ]; then
    logger -t gwatop-celery-watchdog "ping 3회 무응답 + 큐 ${q_end}건 미배수 — gwatop-celery 재시작"
    systemctl restart gwatop-celery || true
else
    logger -t gwatop-celery-watchdog "ping 무응답이나 큐=${q_end}(시작 ${q_start}) — 재시작 보류(오탐 방지)"
fi
exit 0
