# Celery 워커 스케일링 / 우선순위 운영 가이드

AI 콘텐츠 생성(요약·분석·퀴즈·플래시카드·마인드맵·암기·주요개념)과 강의계획서 파싱은
모두 Celery 워커에서 OpenAI 를 호출한다. 체감 속도의 가장 큰 변수는 **워커 동시성**과
**작업 우선순위**다.

## 1. 작업 우선순위 (코드로 적용 완료 — 워커 재시작만 필요)

`app/tasks/celery_app.py` 에 Redis 단일 큐 priority 를 켜 두었다:

- `task_default_priority=5` — 일반 작업(추출/분류/파싱/요약/사용자 직접 생성).
- prefetch 5종은 `priority=9`(최후순위)로 큐잉(`routes/study.py` 의 prefetch 엔드포인트).
- Redis 규칙: **숫자가 작을수록 먼저 소비**(0=최우선).

효과: 파일 진입 시 투기적으로 깔리는 prefetch 가 실작업을 막지 않는다. 별도 큐/`-Q`
옵션이 필요 없고, **워커를 재시작**하면 적용된다. 미지원/오설정이어도 최악은 기존 FIFO.

검증: 워커 재시작 후 로그에 priority 관련 오류가 없는지 확인하고, 파일 여러 개를 빠르게
열어 prefetch 를 깔아둔 상태에서 새 파일 업로드(추출) 가 곧바로 처리되는지 본다.

## 2. 워커 동시성 (systemd — EC2 에서 직접 조정)

현재 `--concurrency=2` (prefork). 이 값이 동시에 처리 가능한 작업 수다. OpenAI 호출은
대부분 네트워크 대기(I/O bound)라 CPU 코어 수보다 크게 잡아도 된다.

권장(인스턴스 RAM/`worker_max_memory_per_child=300MB` 고려):

| 인스턴스        | 권장 concurrency | 메모리 여유 체크 |
|----------------|------------------|------------------|
| t3.small(2GB)  | 3~4              | child×300MB + 앱 |
| t3.medium(4GB) | 5~8              | 넉넉             |
| t3.large(8GB)  | 8~12             | 넉넉             |

`/etc/systemd/system/gwatop-celery.service` 의 ExecStart 에서 조정:

```
ExecStart=/.../celery -A app.tasks.celery_app worker \
  --loglevel=info --concurrency=6 --prefetch-multiplier=1
```

적용:
```
sudo systemctl daemon-reload && sudo systemctl restart gwatop-celery
```

주의:
- OpenAI **rate limit(RPM/TPM)** 이 진짜 상한일 수 있다. concurrency 를 올렸는데
  429 가 늘면 그게 병목 — 모델 tier 의 한도를 먼저 확인.
- `worker_max_memory_per_child` 때문에 child 가 주기적으로 교체되므로, concurrency ×
  300MB 가 인스턴스 RAM 을 넘지 않게 한다.

## 3. (선택) prefetch 전용 워커 분리

더 확실히 격리하려면 prefetch 를 별도 큐 + 별도 저동시성 워커로 빼는 방법도 있다.
현재 priority 방식으로 충분하면 불필요. 필요 시:
- prefetch 태스크를 `queue="low"` 로 라우팅하고,
- 메인 워커는 `-Q celery`, 별도 워커가 `-Q low --concurrency=1` 을 소비.
