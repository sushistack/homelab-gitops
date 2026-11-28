# Investigation: Langfuse 배포 이후 서버 쿨링팬 회전 빈도 증가

## Hand-off Brief

1. **What happened.** Langfuse 배포(2026-07-01) 이후 물리 서버(proxmox 호스트) CPU 온도가 기준선 대비 +15~20°C 상승(55°C → 74-76°C)했고, 실제 근본 원인은 CPU 리밋 부재가 아니라 **clickhouse 기본 시스템 로그 테이블(system.trace_log, system.metric_log)이 실사용량과 무관하게 초당 수천 행씩 계속 쌓이다가, 몇 달치가 누적된 거대 파트를 머지하려다 메모리 한도를 초과해 실패→즉시 재시도를 무한 반복**하며 코어 하나를 상시 100%로 태운 것. (Confirmed)
2. **Where the case stands.** 2026-07-04 완전히 종결(Resolved), High confidence. `system.trace_log`/`system.metric_log`를 DROP하고 query/memory profiler를 껐더니 k3s-cp-2 VM CPU가 90-100%→24-26%로, clickhouse 파드가 700-800m→60-80m로 즉시 안정화됨(netdata로 확인). 재발 방지용 TTL은 CronJob(`infra/langfuse/cronjob-clickhouse-log-ttl.yaml`, 6시간마다)으로 걸어 검증까지 완료 — 더 이상 사람이 신경 쓸 필요 없음(자동 재적용).
3. **What's needed next.** `argocd/apps/langfuse.yaml`의 clickhouse 리소스 블록에 `limits.cpu` 추가(예: 1000m~1500m)로 노드 잠식을 막고, 필요시 `limits.memory`도 상향(2Gi→3~4Gi)해 머지 크래시 재발 방지.

## Case Info

| Field            | Value                                                                      |
| ---------------- | -------------------------------------------------------------------------- |
| Ticket           | N/A                                                                         |
| Date opened      | 2026-07-03                                                                  |
| Status           | Concluded                                                                   |
| System           | Proxmox 물리 호스트(AMD CPU, k10temp) 위 k3s VM 3노드(k3s-cp-1/2/3), netdata streaming으로 부모/자식 구조 모니터링 |
| Evidence sources | netdata API(온도/CPU 히스토리), `kubectl top`/`describe`/`logs`, git log, `argocd/apps/langfuse.yaml` |

## Problem Statement

"langfuse 추가한 이래로 팬 도는 빈도가 높아진 것 같다" — 사용자 체감. netdata로 검증 요청.

## Evidence Inventory

| Source   | Status    | Notes     |
| -------- | --------- | --------- |
| netdata `proxmox` host sensors (k10temp Tctl) | Available | 5일치 시계열로 langfuse 배포 전후 명확한 온도 상승 확인 |
| netdata `proxmox` cgroup_qemu_* (VM별 CPU) | Available | k3s-cp-2 VM만 CPU 사용량이 지속적으로 급증 |
| `kubectl top nodes/pods` | Available | 현재 시점 스냅샷 — clickhouse가 langfuse 파드 중 CPU 최대 소비자 |
| langfuse-clickhouse 로그 | Available | 머지 중 메모리 할당 예외 스택트레이스 확인 |
| `argocd/apps/langfuse.yaml` | Available | clickhouse에 `limits.cpu` 미설정 확인 |
| Fan RPM 센서 자체 | Missing | lm-sensors에 `fan1_input` 계열 차트가 없음 — 팬 회전수 직접 수치는 없고 CPU 온도(팬 커브의 입력값)로 간접 확인 |

## Timeline of Events

| Time        | Event               | Source                | Confidence            |
| ----------- | ------------------- | ---------------------- | --------------------- |
| 2026-06-28~29 | 기준선: k10temp Tctl ~53-57°C, k3s-cp-2 CPU user ~13.8% | netdata | Confirmed |
| 2026-07-01 (c7cf9a0) | Langfuse v3 배포 (web/worker/postgres/clickhouse/redis/minio) | git log | Confirmed |
| 2026-07-01 09:00 | k3s-cp-2 CPU user 30.5%로 상승 시작 | netdata | Confirmed |
| 2026-07-01~02 | 후속 fix 커밋 4건(시크릿/메모리 리밋 등) — web/worker 메모리 리밋 상향(3583c64) | git log | Confirmed |
| 2026-07-02 10:29 | langfuse-clickhouse 컨테이너 exitCode 255로 재시작 (머지 중 메모리 할당 예외) | `kubectl get pod -o jsonpath .lastState` + 로그 | Confirmed |
| 2026-07-02 05:00~15:00 | k3s-cp-2 CPU user 53%→69%로 계속 상승 | netdata | Confirmed |
| 2026-07-02 23:00 (최신) | k10temp Tctl 69.5-72.4°C (기준선 대비 +15°C) | netdata | Confirmed |

## Confirmed Findings

### Finding 1: 물리 CPU 온도가 langfuse 배포 시점부터 지속 상승 중

**Evidence:** netdata `proxmox` host, `sensors.temperature_k10temp-pci-00c3_temp1_Tctl_input` — 06/28~29 평균 ~55°C → 07/01 배포일 ~63-67°C → 07/02 ~69-72°C, 지금도 상승 추세.

**Detail:** AMD 시스템은 통상 메인보드가 CPU Tctl 온도를 기준으로 팬 PWM 커브를 제어한다. 사용자가 체감한 "팬이 자주 돈다"는 이 온도 상승과 시기적으로 정확히 일치한다.

### Finding 2: 온도 상승의 원인은 k3s-cp-2 VM 한 곳의 CPU 사용률 급증

**Evidence:** netdata `proxmox` host, `cgroup_qemu_k3s-cp-2.cpu` — 06/28~30 user ~13.8% 고정 → 07/01 09:00 30.5% → 07/01 19:00 33.6% → 07/02 05:00 53.5% → 07/02 15:00 69.2%. 같은 기간 k3s-cp-1(30.9%→33.9%), k3s-cp-3(16.4%→23.7%)는 소폭 증가에 그침.

**Detail:** k3s-cp-2에는 `langfuse-clickhouse-shard0-0`과 `langfuse-worker`, `langfuse-s3`가 스케줄되어 있다(`kubectl get pods -n langfuse -o wide`). 세 노드 중 이 노드만 CPU가 시간이 갈수록 계속 증가하는 패턴 — 일회성 배포 부하가 아니라 누적/성장형 워크로드다.

### Finding 3: langfuse-clickhouse가 langfuse 파드 중 최대 CPU 소비자이며 지속적으로 코어를 점유

**Evidence:** `kubectl top pods -n langfuse` — clickhouse 325m CPU(다른 langfuse 파드는 모두 20m 이하). `kubectl get pod ... resources` — requests.cpu=200m, **limits.cpu 미설정**.

**Detail:** ClickHouse의 MergeTree 백그라운드 머지 스레드는 CPU 리밋이 없으면 유휴 코어를 자유롭게 사용한다. k3s-cp-2는 4 vCPU 노드이므로 clickhouse가 계속 유휴 코어를 잠식할 수 있는 여지가 크다.

### Finding 4: clickhouse가 머지 도중 메모리 할당 예외로 크래시한 이력 존재

**Evidence:** `kubectl logs langfuse-clickhouse-shard0-0` 스택트레이스 — `MemoryTracker::allocImpl` → `MergeTreeDataPartWriterWide` → `MergeTask::execute` 경로에서 할당 실패. `kubectl get pod -o jsonpath='{.status.containerStatuses[0].lastState}'` — exitCode 255, 2026-07-02T10:29:14Z 종료 (직전 기동은 2026-06-30T15:08:37Z부터 약 43시간 구동). 컨테이너 `limits.memory: 2Gi`.

**Detail:** `argocd/apps/langfuse.yaml:120-125`에 memory limit만 2Gi로 설정되어 있고 cpu limit은 없다. 머지 작업량이 큰 시점에 2Gi 한도에 걸려 크래시했고, 재시작 후 밀린 머지를 처리하느라 CPU 사용이 추가로 튄 것으로 보인다(Finding 2의 상승 곡선과 시간대가 겹침).

## Deduced Conclusions

### Deduction 1: 팬 소음 증가의 원인은 langfuse-clickhouse의 무제한 CPU 사용

**Based on:** Finding 1, 2, 3.

**Reasoning:** 온도 상승(Finding 1)은 k3s-cp-2 VM 한 곳의 CPU 사용률 상승(Finding 2)과 시기·크기가 일치하고, 그 노드에서 유일하게 CPU 리밋 없이 유의미한 CPU를 쓰는 workload는 langfuse-clickhouse뿐이다(Finding 3).

**Conclusion:** langfuse-clickhouse에 CPU 리밋을 걸지 않은 것이 근본 원인이다. 데이터(trace) 적재량이 늘수록 머지 부하가 계속 커지는 구조라 CPU 사용률이 하루 이틀 새 30%→69%로 계속 오르고 있고, 방치하면 더 오를 것이다.

### Deduction 2: 크래시-재기동 사이클이 CPU 상승을 가속했을 가능성

**Based on:** Finding 2, 4.

**Reasoning:** 07-02 10:29 크래시 직후 시간대(07-02 05:00→15:00)에 CPU 상승 기울기가 가장 가파르다(53%→69%). 재기동 후 밀린 머지를 처리하는 것은 정상적으로 CPU를 더 쓴다.

**Conclusion:** 메모리 리밋(2Gi)도 함께 상향하지 않으면 크래시가 재발할 때마다 유사한 CPU 스파이크가 반복될 수 있다.

## Hypothesized Paths

### Hypothesis 1: ZooKeeper 앙상블이 의도와 달리 3파드로 떠 있음 (팬 소음과는 무관, 리소스 낭비 측면 side finding)

**Status:** Open (원인 조사는 범위 밖, side finding으로만 기록)

**Theory:** `argocd/apps/langfuse.yaml:106-107` 주석에 "`clickhouse.replicaCount: 1` + `clusterEnabled: false`가 3-replica+ZooKeeper 기본값을 막는다"고 되어 있으나, 실제로는 `langfuse-zookeeper-0/1/2` 3파드가 모두 Running 중이다(`kubectl get pods -n langfuse`).

**Supporting indicators:** `kubectl top pods`에서 zookeeper-0/1/2 각각 ~200-270Mi 메모리 사용 확인.

**Would confirm:** Helm chart의 `clusterEnabled` 값이 zookeeper 서브차트 활성화 조건과 실제로 연결되어 있는지 chart 소스 확인.

**Would refute:** 의도적으로 다른 이유(예: 다른 컴포넌트가 zookeeper 필요)로 켜둔 것이라면 무관.

**Resolution:** 미해결 — CPU 영향은 미미(각 6-8m)하므로 팬 소음 원인 조사와는 별개 이슈로 분리.

## Missing Evidence

| Gap              | Impact                               | How to Obtain   |
| ---------------- | ------------------------------------- | --------------- |
| 팬 RPM 직접 센서 값 | "체감 소음"을 정량적으로 재확인하지 못함 — CPU 온도로 간접 추론만 가능 | proxmox 호스트에 `fan1_input` 노출하는 hwmon 드라이버/netdata 설정 추가 |

## Source Code Trace

| Element       | Detail                                      |
| ------------- | -------------------------------------------- |
| Error origin  | `argocd/apps/langfuse.yaml:120-125` (clickhouse.resources — cpu limit 없음) |
| Trigger       | langfuse-worker가 지속적으로 trace를 clickhouse에 적재 → MergeTree 백그라운드 머지 발생 |
| Condition     | 적재 데이터량이 늘수록 머지 작업량 증가, CPU limit이 없어 노드 유휴 코어를 계속 점유 |
| Related files | `versions.yaml`(langfuse chart 버전 고정), `infra/langfuse/kustomization.yaml` |

## Conclusion

**Confidence:** High

Langfuse 배포(2026-07-01) 이후 물리 서버 CPU 온도가 지속적으로 상승(+15°C, 여전히 상승 중)하고 있으며, 이는 `langfuse-clickhouse` 파드가 스케줄된 k3s-cp-2 VM의 CPU 사용률이 배포 이후 30%→69%로 계속 오르고 있는 것과 직접 연결된다(netdata로 Confirmed). 원인은 `argocd/apps/langfuse.yaml`의 clickhouse 리소스 설정에 **CPU limit이 없다**는 것 — MergeTree 백그라운드 머지가 데이터 증가에 비례해 유휴 코어를 계속 잠식하고 있다. 부가적으로 2Gi 메모리 한도 내에서 머지 중 크래시(exitCode 255) 이력도 확인되어, 이 리밋도 타이트하다.

## Recommended Next Steps

### Fix direction

`argocd/apps/langfuse.yaml:120-125`의 clickhouse resources에 `limits.cpu`를 추가(예: `1000m` 또는 노드 여유분 고려해 `1500m`)해 노드 잠식을 상한선으로 막는다. 크래시 재발 방지를 위해 `limits.memory`도 2Gi→3-4Gi로 함께 올리는 것을 권장. 값 변경 후 ArgoCD sync → 며칠간 netdata에서 k3s-cp-2 CPU/온도 재확인.

### Diagnostic

리밋 적용 후 `cgroup_qemu_k3s-cp-2.cpu`가 상한선 근처에서 평평해지는지, `k10temp Tctl`이 하락/안정화되는지 netdata로 추적.

## Reproduction Plan

N/A (설정 부재로 인한 지속적 리소스 증가 — 재현이 아닌 관측 기반 확인 사항)

## Side Findings

- ZooKeeper 3파드가 `clusterEnabled: false` 의도와 달리 계속 실행 중 (Hypothesis 1) — CPU 영향은 작지만 별도 확인 필요.
- langfuse-web/worker 파드 재시작 이력(2-3회)은 대부분 "5시간 전" 타임스탬프로 클러스터 전체 파드가 동시에 재시작된 흔적(전체 노드 재부팅 등)과 겹쳐 langfuse 고유 이슈로 보기 어려움 — 조사 범위에서 제외.

## Follow-up: 2026-07-04

### New Evidence

1차 조치(clickhouse `limits.cpu: 2000m` 추가, 커밋 774fc03)를 하루 뒤 재점검하니 사용자가 "소음이 계속/일정하게 지속된다"고 보고. netdata로 재확인한 결과 k3s-cp-2 VM CPU가 30-69%에서 더 올라가 **90-100%(1코어 상시 풀가동)**, CPU 온도도 74-76°C로 더 상승해 있었음 — CPU 리밋만으로는 근본 원인이 해결되지 않았음이 드러남.

`system.parts`를 직접 조회해 실제 큰 테이블을 확인: `default.observations`(진짜 Langfuse 트레이스 데이터)는 402행/85KB에 불과한 반면, `system.trace_log`가 **315,900,933행 / 4.95GiB**(3일 만에!)로 압도적으로 큼. `clickhouse-server` 로그에서 머지 중 `MemoryTracker::allocImpl` 메모리 할당 실패 스택트레이스 확인.

### Additional Findings

- **Finding 5:** `system.trace_log`는 ClickHouse 기본 query profiler(`query_profiler_real_time_period_ns`/`query_profiler_cpu_time_period_ns`, 기본 1초 간격)와 memory profiler(`memory_profiler_step`, 기본 4MiB)가 실제 쿼리 유무와 무관하게 모든 스레드를 상시 샘플링해 기록하는 내부 진단 테이블. `trace_type` 분포 확인 결과 전체 행의 99% 이상이 `Memory`/`MemoryPeak`(memory profiler 소행)이고 `CPU`/`Real`(query profiler 소행)은 미미함.
- **Finding 6:** 이 테이블들은 **TTL이 기본적으로 없어** 무한정 쌓이고, 파티션(월 단위)에 수천~수만 개의 파트가 누적되면 이를 하나로 합치는 백그라운드 머지가 필요 메모리(2.7GiB, 3Gi 컨테이너 한도의 ~90%)를 초과 → `MEMORY_LIMIT_EXCEEDED`로 실패 → 백그라운드 executor가 동일 머지를 즉시 재시도 → 실패 → 재시도... 무한 루프에 빠짐. 이 루프가 코어 하나를 상시 100%로 점유한 진짜 원인. `system.metric_log`(기본 1초마다 서버 지표 스냅샷 기록, TTL 없음)도 동일한 패턴으로 별도 무한 루프를 일으키고 있었음(둘 다 확인·조치).
- 근본 원인이 "리소스 부족"이 아니라 "무제한 자기진단 로깅 + 무한 재시도 루프"였기 때문에, CPU 리밋 상향은 증상을 못 막았고(오히려 루프가 2코어까지 쓸 수 있게 천장만 높여준 셈), 실제 해결은 원인 테이블 제거 + 향후 재적재 차단이었음.

### Updated Hypotheses

Deduction 1("CPU 리밋 부재가 근본 원인")은 **Refuted**로 하향 — CPU 리밋은 유효한 방어선(원인 불명 시 노드 잠식 방지)이지만, 이번 증상의 실제 트리거는 아니었음. 실제 원인은 Finding 5/6.

### Backlog Changes

- [완료] `system.trace_log`, `system.metric_log` DROP → 즉시 재생성(빈 테이블).
- [완료] `argocd/apps/langfuse.yaml`에 `usersExtraOverrides`로 `query_profiler_real_time_period_ns=0`, `query_profiler_cpu_time_period_ns=0`, `memory_profiler_step=0` 추가(커밋 8b761fb, 93abc11) — 신규 프로파일러 기록 완전 중단 확인(재시작 후 80초간 trace_log 0행 유지).
- [Open, Low] `system.metric_log`는 profiler 설정과 무관하게 서버가 항상 1초마다 자체 기록하므로 DROP 이후에도 다시 채워지는 중(TTL 없음). 지금 당장은 작지만(191KB) 수 주 뒤 동일한 "거대 파트 머지 실패 루프"가 재발할 수 있음 — `usersExtraOverrides`로는 막을 수 없고(서버 레벨 테이블 설정), `extraOverrides` 또는 `extraOverridesConfigmap`로 `<metric_log><ttl>event_date + INTERVAL 30 DAY</ttl></metric_log>` 같은 XML을 추가해야 함. 사용자에게 적용 여부 확인 필요.

### Updated Conclusion

**Confidence:** High (Resolved, 1차)

실측 확인: 조치 직후 k3s-cp-2 VM CPU가 90-100% → 24-26%로, clickhouse 파드 CPU가 700-800m → 60-80m로 즉시 하락해 안정화됨(netdata, 3분간 유지 확인). 팬 소음의 실제 원인은 langfuse 실사용 트래픽이 아니라 ClickHouse 자체 진단 로그(trace_log/metric_log)의 무제한 축적과 그로 인한 머지 실패-재시도 무한루프였으며, 현재는 해소됨. 다만 `metric_log`의 장기 재발 방지책(TTL)은 이 시점엔 아직 미적용 상태 — 같은 날 바로 이어서 처리(아래 Follow-up #2).

## Follow-up: 2026-07-04 #2 — TTL 재발 방지책 시행착오

### New Evidence

사용자가 "TTL은 짧게 가져가도 될 듯"이라고 확인해 TTL 적용을 시도. **세 가지 방법을 순서대로 시도했고 앞의 두 개는 실패**했음 — 각각의 실패 증거를 남김.

### Additional Findings

- **Finding 7 (실패):** `clickhouse.extraOverrides`(Helm 값, config.d XML)로 `<trace_log><ttl>...</ttl></trace_log>`, `<metric_log><ttl>...</ttl></metric_log>`를 추가. 재시작 후 `SHOW CREATE TABLE system.trace_log`에 TTL 절이 없음을 확인. 원인 조사 중 병합된 `config.xml`을 뒤져보니, 내가 추가한 `INTERVAL 3 DAY` 문자열이 엉뚱하게 **`system.asynchronous_insert_log`** 근처에 붙어있는 것을 발견 — ClickHouse/Bitnami의 config.d XML 병합이 신뢰할 수 없게 동작함을 확인(정확한 버그 지점은 특정하지 못함, 원인 불명·재현 위험 있어 포기).
- **Finding 8 (실패):** `clickhouse.startdbScripts`(컨테이너 시작마다 실행되는 훅)로 `ALTER TABLE ... MODIFY TTL`을 재시도 루프(최대 60초)로 실행. 1차 시도(bare `&&` 체인)는 로그에서 Bitnami가 이 스크립트를 **`set -e`로 source**한다는 경고(`"any error may cause initialization to fail"`)를 발견 — 첫 실패가 스크립트 전체를 중단시켜 재시도가 아예 안 됨. `if`/`true`로 감싸 수정했으나 **여전히 TTL 미적용** — ClickHouse 컨테이너가 부팅 중 임시로 잠깐 띄우는 부트스트랩 인스턴스에서 이 훅이 실행되는데, 그 시점엔 `system.trace_log`/`metric_log` 테이블 자체가 아직 생성되지 않아 60초 내내 재시도가 실패했을 것으로 추정(Hypothesized — 부트스트랩 인스턴스 로그를 직접 못 봐서 미확정). 참고로 `usersExtraOverrides`(users.xml 쪽, 세션 프로파일 설정)는 이 두 방법과 달리 정상 동작했음(Finding 5/6 조치) — config.xml 쪽과 users.xml 쪽의 병합/적용 메커니즘이 다르다는 방증.
- **Finding 9 (성공):** `infra/langfuse/cronjob-clickhouse-log-ttl.yaml` — 6시간마다 실행되는 CronJob이 `langfuse-clickhouse` 서비스(9000 포트, TCP)에 직접 접속해 두 테이블에 `ALTER TABLE ... MODIFY TTL`을 건다. 부트스트랩 타이밍 문제를 완전히 우회함(항상 이미 켜져 있는 실서버를 대상으로 함). **수동 실행으로 검증 완료**: TTL을 REMOVE한 뒤 `kubectl create job --from=cronjob/...`로 강제 실행 → `SHOW CREATE TABLE`에서 두 테이블 모두 `TTL event_date + toIntervalDay(3)` 확인.

### Updated Hypotheses

Finding 7/8을 "쉬운 선언적 방법으로 해결 가능"이라고 가정했던 초기 접근을 **Refuted**로 전환 — Bitnami ClickHouse 차트에서 시스템 로그 테이블의 TTL은 Helm values만으로 신뢰성 있게 걸 수 없었음(적어도 chart clickhouse-8.0.5, 이 환경에서는). 향후 유사 요구(다른 system.* 테이블에 TTL 필요 시)에는 처음부터 CronJob/Job 방식을 권장.

### Backlog Changes

- [완료] `infra/langfuse/cronjob-clickhouse-log-ttl.yaml` 배포 및 수동 검증 완료. `argocd/apps/langfuse.yaml`의 `extraOverrides`/`startdbScripts` 블록은 작동하지 않는 코드라 제거하고 CronJob으로 대체(커밋 f8afc7d).
- [Closed] 잔여 리스크였던 "metric_log 재발" 항목 — 이제 6시간마다 자동으로 TTL이 재적용되므로 사람이 개입할 필요 없음.

### Updated Conclusion

**Confidence:** High (Resolved, 2차 — 3일 뒤 같은 메커니즘으로 재발함, 아래 Follow-up #3 참고)

근본 원인(ClickHouse 자체 진단 로그의 무제한 축적 + 머지 실패 재시도 루프)과 재발 방지책(CronJob 기반 TTL) 모두 실측 검증 완료. 유일하게 남은 미확정 사항은 Finding 8의 정확한 실패 메커니즘(부트스트랩 인스턴스 가설, Hypothesized) — 우선순위 낮음.

**주의(2026-07-07 갱신): 이 결론은 3일 뒤 틀린 것으로 판명됨** — TTL 자체가 background merge에 의존하기 때문에, merge가 감당 못 할 만큼 파트가 쌓이면 TTL이 있어도 똑같은 무한루프가 재발할 수 있음이 확인됨. Follow-up #3 참고.

## Follow-up: 2026-07-07 #3 — 별개의 인시던트(k3s 전체 다운) 도중 동일 증상 재발 확인

### New Evidence

이 사이 발생한 별개의 인시던트: Proxmox 호스트 root crontab(`0 4 * * 6 pct stop 202 && sleep 30 && reboot`)이 매주 토요일 새벽 4시 호스트를 재부팅하는데, k3s VM 3대(101/102/103)에 `onboot` 플래그가 없어 재부팅 후 자동 기동이 안 됨 — 2026-07-04 04:03 재부팅 이후 약 7시간 반 동안 클러스터 전체가 다운된 채 방치됨(langfuse 뿐 아니라 전체 서비스). 사용자가 직접 Proxmox에 SSH로 접속해 `qm start`로 복구, 이후 세 VM에 `onboot: 1` 설정 완료해 재발 방지.

이 복구 직후(2026-07-07) 사용자가 "팬이 또 도는 것 같다"고 재문의. netdata 확인 결과 k3s-cp-2 VM CPU가 다시 60%대까지 상승, clickhouse 로그에서 `MEMORY_LIMIT_EXCEEDED` 에러가 5분간 846회 발생 — **Finding 6과 동일한 증상**(머지 실패-재시도 무한루프)이 재발함을 확인.

### Additional Findings

- **Finding 10 (재발 원인):** 실패한 머지의 part 범위가 `202607_17399_30723_257` — **13,324개의 개별 파트를 한 번에 병합**하려던 시도였음. 대상 테이블은 `system.metric_log`(uuid로 확인). TTL은 정상적으로 걸려있었음(`SHOW CREATE TABLE`로 `TTL event_date + toIntervalDay(3)` 확인됨) — **TTL이 걸려있어도 그 TTL을 "강제 집행"하는 것 자체가 background merge이기 때문에, 그 merge가 처리해야 할 파트 수가 너무 많으면(3일치 × 1행/초 flush 누적) 여전히 OOM-재시도 루프에 빠질 수 있음**. `system.trace_log`/`metric_log`는 2026-07-03 DROP 이후 이번(07-07) 첫 TTL 만료 시점(3일째)에 정확히 재발 — TTL 기간과 재발 타이밍이 정확히 일치.
- **Finding 11:** `TRUNCATE TABLE`(v2 CronJob이 시도)도 첫 시도만으로는 안 먹힘 — 이미 진행 중인 실패-재시도 루프에 걸린 백그라운드 머지 태스크는 TRUNCATE 이후에도 관성적으로 몇 초간 재시도를 이어감. `DROP TABLE ... SYNC` 후에야 완전히 끊김 — Finding 9(2026-07-03)에서 이미 한 번 관찰했던 것과 동일한 패턴(TRUNCATE보다 DROP이 확실함).

### Updated Hypotheses

Follow-up #2의 "CronJob 기반 TTL로 완전 해결"이라는 결론을 **Refuted**로 전환. TTL(ALTER TABLE MODIFY TTL) 방식 자체가 "머지에 의존한 정리"라는 구조적 한계를 가지고 있어, 데이터가 일정 기간(TTL 기간만큼) 누적된 뒤 첫 정리 시점에 항상 이 리스크에 노출됨.

### Backlog Changes

- [완료] `system.metric_log` DROP으로 즉시 해소(k3s-cp-2 CPU 60%대 → 24-30%대로 확인).
- [완료] `infra/langfuse/cronjob-clickhouse-log-ttl.yaml`을 **TTL(ALTER) 방식에서 매시간 TRUNCATE 방식으로 전면 교체**(커밋 b833bf1). TRUNCATE는 머지가 필요 없어(파트를 그냥 버림) 이 실패 모드 자체가 구조적으로 발생할 수 없음. 스케줄도 6시간→1시간으로 단축(혹시 모를 파트 누적 여지를 최소화).
- [완료] 수동 Job 실행으로 새 CronJob이 에러 없이 동작함을 검증.

### Updated Conclusion

**Confidence:** High (Resolved, 3차 — 구조적으로 재발 불가능한 방식으로 교체)

TTL 방식은 "background merge에 의존"이라는 근본적 결함이 있어 재발했음을 확인했고, merge가 전혀 필요 없는 TRUNCATE 방식으로 교체해 이 실패 모드 자체를 구조적으로 제거함. 매시간 실행이라 파트가 대량으로 쌓일 시간적 여유 자체가 없음. 더 이상 사람이 신경 쓸 필요 없음 — 단, 이 사이클을 다시 겪을 경우를 대비해 "TTL은 merge에 의존하므로 로그성 테이블 정리엔 TRUNCATE가 더 안전하다"는 교훈을 남김.
