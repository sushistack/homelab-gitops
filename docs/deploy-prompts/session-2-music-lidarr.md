# Session 2 — 음악 자동수집 (Lidarr + slskd + soularr) · k3s

> bmad-quick-dev 세션에 아래 전체를 붙여넣어라.
> 목표: **무손실(FLAC)/정식 릴리스** 음악을 자동 수집해 Navidrome 라이브러리를 채운다.
> 토렌트/Usenet 음악 인덱서는 FLAC에 약하므로 **소스는 Soulseek(slskd)**, soularr가 Lidarr 위시리스트→slskd 다운로드를 잇는다.

---

이 repo는 k3s + Argo CD GitOps 홈랩이다. 새 앱은 `workloads/<name>/` 디렉터리로 추가하면
ApplicationSet가 자동으로 Argo CD Application을 생성한다(디렉터리당 1개). 스켈레톤은
`workloads/_template/`에 있고, 가장 비슷한 기존 workload를 복사해서 시작하라.

반드시 지킬 컨벤션:
- 이미지: digest 핀(@sha256). 위에 재해결 커맨드 + 날짜 주석 남길 것
  (예시: workloads/komga/deployment-suwayomi.yaml 참고).
- 매니페스트: namespace.yaml / kustomization.yaml(resources 나열) / deployment / service.
  Deployment엔 resources requests·limits, startup/readiness/liveness probe, env TZ=Asia/Seoul.
- 스토리지: 앱 설정·DB는 Longhorn PVC. 이미지가 non-root uid면 busybox initContainer로
  데이터 디렉터리 chown(워크로드 komga/deployment-suwayomi.yaml의 data-fix 패턴 그대로).
- 시크릿: 절대 평문 금지. sealed-secrets(kubeseal) 사용.
- 인그레스: traefik.io/v1alpha1 IngressRoute (containo.us API 금지). websecure(:443) 라우트 1개 +
  web(:80) → https redirect Middleware 1개. TLS는 cert-manager Certificate(DNS-01), secretName <app>-tls.
  Host는 ${SECRET:DOMAIN_<APP>} 치환 사용. 패턴은 workloads/komga/ingressroute.yaml 그대로.
- 노출 모델: 관리자 UI는 전부 INTERNAL = CF Access(Google SSO) 뒤. 패턴:
  external-dns target 어노테이션 `761ca633-e9d6-4af8-8508-727bba00f0a9.cfargotunnel.com` 달고,
  CF Access로만 게이트. workloads/komga/ingressroute.yaml의 suwayomi 블록이 INTERNAL 레퍼런스다.
- runbook.md 추가(workloads/_template/runbook.md 참고).

작업이 끝나면 kustomize build로 렌더만 검증하고(클러스터 apply 금지), 변경 요약을 남겨라.

**접근**: 디스크/디렉터리 작업(`/mnt/manga/music` 생성, `qm resize 101` 등)은 Proxmox 호스트 = `ssh root@10.0.0.2`.
k3s-cp-1(노드 101)도 여기서 접근.

---

[작업] workloads/lidarr/ 한 디렉터리에 Deployment 3개(한 네임스페이스, komga+suwayomi 다컴포넌트 패턴):

1. **lidarr** — lscr.io/linuxserver/lidarr. 라이브러리 매니저(아티스트 모니터→missing 추적, MusicBrainz 태깅·정리).
   설정/DB는 Longhorn PVC. PUID/PGID 1000.
2. **slskd** — slskd/slskd. 헤드리스 Soulseek 데몬 = FLAC 실제 다운로드 소스. 설정 Longhorn PVC.
3. **soularr** — mrusse08/soularr (커뮤니티). Lidarr의 wanted/missing을 읽어 slskd에서 검색·다운로드→Lidarr가 import.
   UI 없음. 주기 실행(루프/cron).

❗핵심 스토리지 — **node-local PV 패턴 (만화 라이브러리와 동일, RWX-Longhorn 쓰지 말 것)**:
- 음악 라이브러리는 **k3s-cp-1(노드 101)의 전용 디스크에 static `local` PV**로 둔다.
  레퍼런스: `workloads/komga/pvc-manga-local.yaml` (komga-manga-local). 그대로 베껴라:
  static `local` PV + `nodeAffinity` k3s-cp-1 + accessMode RWX + Retain + claimRef.
  `local` PV의 nodeAffinity가 **소비 pod(Navidrome/Lidarr/slskd)를 k3s-cp-1에 자동 co-locate** → RWO/RWX 고민 불필요.
- 디스크: **신규 디스크 없음 — 기존 만화 디스크(`/mnt/manga`, k3s-cp-1)를 공유**한다.
  음악용 PV는 그 디스크의 하위 경로 `/mnt/manga/music`를 가리키는 별도 static `local` PV로 만든다
  (komga-manga-local과 같은 형태, path만 `/mnt/manga/music`, claimRef는 음악 namespace).
  ⚠️ 같은 물리 디스크라 **용량·SPOF 공유** — 음악이 디스크를 꽉 채우면 만화도 영향(현재 200G 중 만화 ~90G라 여유는 충분). 필요 시 `qm resize 101`로 온라인 확장.
- **마이그레이션**: 현재 Navidrome 음악은 Longhorn `navidrome-music` PVC다 (workloads/navidrome/pvc.yaml).
  → `/mnt/manga/music`로 복사 후 Navidrome deployment를 새 local PVC로 repoint. 기존 Longhorn PVC는 Retain(데이터 안전).
  만화 5.6에서 한 "복사→static local PV repoint"와 동일 절차.
- 마운트: Navidrome(ro 또는 rw), Lidarr(rw, root folder=라이브러리 루트), slskd 다운로드 디렉터리는
  같은 볼륨 하위(예: `/mnt/manga/music/.incoming`) → Lidarr import 시 같은 fs 내 이동(하드링크/즉시이동). soularr는 미디어 마운트 불필요.

시크릿(sealed-secret):
- slskd: Soulseek 계정 username/password.
- soularr: Lidarr API key + slskd 접속정보. (config 파일/env)

노출: lidarr UI(8686), slskd UI(5030) 둘 다 INTERNAL(CF Access). soularr는 UI 없음.

백업: lidarr DB는 backup-cronjob 대상. 음악 파일(navidrome-music)은 재취득 가능 → 기존 navidrome 정책 따름(스냅샷만, R2 덤프 X).
