# Deferred — 노드 팬 주기적 가동 원인 추적

상태: **미해결 (조사 중)** · 작성일: 2026-06-22 · 관련 커밋: `ae83cff` (longhorn dataLocality best-effort)

---

## 증상

노드 팬이 **주기적으로 계속 가동**된다. `ae83cff` 에서 Longhorn `dataLocality: best-effort`
로 VM 간 디스크 I/O를 줄였지만 팬 패턴은 **변화 없음**.

이게 핵심 단서다: 디스크 I/O 튜닝이 팬에 영향을 못 줬다는 건 **병목이 디스크가 아니라
CPU(또는 디스크라 해도 dataLocality가 못 잡는 워크로드)** 라는 뜻.

---

## 추측 (Hypotheses) — 의심 순위

### H1 (최유력) — `trade-monitor` CronJob의 매분 콜드스타트 CPU 스파이크

- 파일: [workloads/trade-monitor/cronjob.yaml](../workloads/trade-monitor/cronjob.yaml)
- `schedule: "* * * * *"` — **매 1분마다** 새 Pod 생성.
- 이미지가 무거운 **matplotlib / pandas** 스택. 매 사이클마다:
  1. 컨테이너 콜드스타트
  2. Python 인터프리터 + matplotlib/pandas import ← **CPU 폭발 지점**
  3. Binance/Yahoo OHLCV fetch
  4. 240×240 JPEG 렌더링 → LAN 디스플레이로 multipart POST
- `cronjob.yaml:47-48` — **CPU limit이 의도적으로 없음** (`no CPU limit -> no CFS throttle`).
  스파이크가 코어를 풀로 점유 가능 → 팬 즉시 램프업.
- 파일 주석이 이미 이 리스크를 명시: `🔴 Reconciliation 2 — every-minute churn: a fresh
  pod spins each cycle on a heavy matplotlib/pandas image.`
- **예상 팬 패턴: ~60초 주기의 톱니파** (매분 올랐다 내렸다).
- 왜 dataLocality 무효였나: 이 워크로드는 PVC 없는 **stateless·CPU 바운드** 배치.
  디스크를 거의 안 건드린다.

### H2 — Navidrome 15분 라이브러리 스캔 (디스크 read 스파이크)

- 파일: [workloads/navidrome/configmap.yaml:14](../workloads/navidrome/configmap.yaml#L14)
- `ND_AUTOIMPORTSCANINTERVAL: "900"` — 15분마다 음악 폴더 전체 스캔.
- 디스크 read 위주라 dataLocality(쓰기 지역성 위주)로는 못 잡았을 수 있음.
- **예상 팬 패턴: ~15분 주기**.

### H3 — `ops-alerts` CronJob 15분 주기

- 파일: [infra/ops-alerts/cronjob.yaml:9](../infra/ops-alerts/cronjob.yaml#L9)
- `schedule: "*/15 * * * *"`. 경량일 가능성 높으나 H2와 주기가 겹쳐 합산 부하 가능.

### H4 — Longhorn BackupTarget 폴링

- 파일: [infra/longhorn-backup/backuptarget.yaml:17](../infra/longhorn-backup/backuptarget.yaml#L17)
- `pollInterval: 5m0s`. 경량 폴링이라 단독으로 팬을 돌릴 가능성은 낮음.

### 비유력 — 6h~12h 주기 백업 CronJob들

- karakeep/anytype/ntfy/miniflux/navidrome/komga/vaultwarden/n8n 백업, longhorn RecurringJob(12h).
- 주기가 길어 "계속 도는" 체감과는 안 맞음. 다만 :30~:50 슬롯에 몰려 있어 6시간마다
  한 번씩은 동시다발 부하가 날 수 있음(별개 이슈).

---

## 검증 (Verification)

먼저 **팬 주기를 측정**해서 가설을 좁힌다:
- ~60초 주기  → **H1 (trade-monitor) 확정**
- ~15분 주기  → **H2/H3 (navidrome / ops-alerts)**
- ~5분 주기   → H4

### 명령어

```bash
# 1) CPU 상위 소비자 — 스파이크 순간에 실행
kubectl top pods -A --sort-by=cpu | head -20
kubectl top nodes

# 2) trade-monitor가 정말 매분 새 pod을 띄우는지 (H1)
kubectl get pods -n trade-monitor --watch
#   → 60초마다 Pending→Running→Completed 사이클이면 H1.

# 3) trade-monitor 한 사이클의 실제 CPU/소요시간
kubectl get jobs -n trade-monitor --sort-by=.metadata.creationTimestamp | tail -5
kubectl logs -n trade-monitor <job-pod> --timestamps   # import~렌더 구간 길이 확인

# 4) navidrome 스캔 타이밍 (H2)
kubectl logs -n navidrome deploy/navidrome | grep -i scan
#   → 15분 간격 scan 로그 ↔ 팬 램프 시각 대조

# 5) 노드에서 직접(가능하면) — 어떤 프로세스가 코어를 먹는지
#   ssh <node> 후:  pidstat 1 / top -b -n1 / turbostat
```

### 판정 기준

| 측정된 팬 주기 | 결론 | 다음 액션 |
|---|---|---|
| ~60초 | H1 확정 | 아래 S1 적용 |
| ~15분 | H2/H3 | S2 적용, 필요시 ops-alerts 경량화 |
| ~5분 | H4 | pollInterval 상향 검토 |
| 불규칙·6h마다 | 백업 클러스터링 | 백업 스케줄 분산(별도 이슈) |

---

## 해결 방안 (Remediation)

### S1 — trade-monitor: 매분 CronJob → 따뜻한 Deployment + 내부 sleep 루프  *(H1 대응)*

cronjob.yaml 주석에 이미 적힌 공식 fallback. 핵심 효과: **매분 반복되는 인터프리터/라이브러리
import 콜드스타트 비용을 제거** → CPU 스파이크의 톱니파가 사라짐.

- CronJob → `Deployment` (replicas: 1)로 전환.
- 컨테이너가 내부에서 `while true; do <한 사이클>; sleep 60; done` (이미지가 1회용 진입점이면
  엔트리포인트/커맨드 조정 필요 — trade.monitor 레포 측 변경 동반 가능).
- import는 프로세스 기동 시 **단 1회** → 이후엔 메모리에 상주, 매분은 fetch+렌더만.
- 트레이드오프: 상시 RSS 점유(현재 limit 512Mi 유지 가능), 단일 프로세스라
  `concurrencyPolicy: Forbid`로 막던 중첩 보호는 `sleep`이 대체.
- 적용 시 cronjob.yaml 주석대로 **deviation 기록**.

차선책(코드 변경 없이 완화만):
- 주기를 `*/2` 또는 `*/5`로 낮춰 스파이크 빈도↓ (디스플레이 갱신 주기 허용 범위 확인 필요).
- CPU limit을 **추가**하면 CFS throttle로 스파이크 피크는 깎이나 런타임이 늘어
  `activeDeadlineSeconds: 55`를 넘길 수 있음 — 권장 안 함.

### S2 — navidrome 스캔 간격 완화  *(H2 대응 — 제안, 미적용)*

- `ND_AUTOIMPORTSCANINTERVAL`를 `900`(15분) → **`43200`(12시간)** 으로 상향 (초 단위). [configmap.yaml:14](../workloads/navidrome/configmap.yaml#L14)
- 트레이드오프: 새 트랙이 최대 12시간 뒤에 인식됨. 라이브러리 변경 빈도가 낮으면 수용 가능.
- 즉시 인식이 필요하면 navidrome UI/`navidrome scan` 수동 트리거 가능.
- 적용 시 주의: `envFrom: configMapRef`는 Pod 시작 시 1회 주입 → 머지 후 deployment rollout(재시작) 필요.
- (선택) watcher 기반 자동 스캔으로 전환하면 폴링 자체를 제거 가능.

### S3 — 노드 레벨 팬 곡선 (근본이 아닌 완화책)

- 워크로드 부하가 정상 범위인데 팬이 과민하면 BMC/IPMI 또는 노드 OS의 **팬 커브가
  너무 공격적**일 수 있음. fan curve를 완만하게(낮은 온도 임계에서 저 RPM) 조정.
- 단, 이건 GitOps 레포 밖(하드웨어/BIOS) 영역이라 git 히스토리에 안 남음.
- **원인(S1/S2)을 먼저 잡고**, 그래도 과민하면 마지막에 적용.

---

## 결정 로그

- 2026-06-22: 증상 접수, H1~H4 도출. **검증 우선** — 팬 주기 측정 전엔 코드 변경 보류.
- (다음) 검증 결과 → 해당 S 적용 → 이 문서 상태 업데이트.
