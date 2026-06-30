# Self-Hosted App Stack — 최신 대체재 정리

> 기준: 2026년 상반기 / 홈랩 + k3s 환경 기준

> ⚠️ **읽는 법**: 아래 **미디어 / *arr / 다운로드** 섹션은 현재 k3s에 **미배포**다.
> Jellyfin은 Proxmox VM에서 수동 운영 중이고, 이 섹션들은 그걸 자동화하는 **구축 로드맵**으로 읽어야 한다 (폐기 대상 아님).
> 실제 k3s에 돌고 있는 앱 목록은 맨 아래 [**🟢 실제 배포 중 (k3s)**](#-실제-배포-중-k3s--doc-누락분) 참고.

> 🧭 **확정 아키텍처 (2026-06)**:
> - **영상** (Jellyfin + *arr): GPU passthrough VM에 직접(docker compose). 미디어가 VM 디스크에 있고, 하드링크/즉시이동 위해 다운로드·라이브러리 같은 fs. 디스크리트 GPU 1개=VM 1개라 GPU 쓰는 Jellyfin·Immich는 같은 VM.
> - **음악** (Lidarr + slskd + soularr): k3s. Navidrome 라이브러리(`navidrome-music` PVC)가 k3s라 거기 co-locate. 목표 = FLAC/정식 릴리스 → 기존 자작 yt-dlp/Last.fm(lossy) 대체.
> - 구축 프롬프트: `docs/deploy-prompts/`.

---

## 🎬 미디어 서버 / 스트리밍

| 기존 | 대체 | 상태 | 비고 |
|------|------|------|------|
| **Plex** | **Jellyfin** | ⚠️ 대체 권장 | Plex, 2025년 4월부터 외부 스트리밍 유료화 (Plex Pass $250 평생). Jellyfin은 완전 무료 + 하드웨어 트랜스코딩 무료. 가족 공유만 한다면 Jellyfin으로 이전 추천 |
| **Tautulli** | **Jellystat** | ✅ 대체 가능 | Tautulli는 Plex 전용. Jellyfin 이전 시 Jellystat으로 대체 (동일 기능) |
| **Overseerr** | **Seerr** (구 Jellyseerr) | 🔴 대체 필수 | Overseerr 2024년 GitHub 아카이브(유지보수 종료). Jellyseerr 팀과 합쳐져 **Seerr**로 통합 출시. Plex/Jellyfin/Emby 모두 지원 |

---

## 🔄 *arr 스택 / 자동화

| 기존 | 대체 | 상태 | 비고 |
|------|------|------|------|
| **Radarr** | - | ✅ 유지 | 현재도 활발히 개발 중. 대체 불필요 |
| **Sonarr** | - | ✅ 유지 | 동일. 대체 불필요 |
| **Lidarr** | - | ✅ 유지 | 동일. 단 **메타데이터 서버 이슈가 고질적** → 요즘은 `Lidarr + slskd(헤드리스 Soulseek) + soularr` 조합으로 위시리스트를 Soulseek에서 자동 수집하는 셋업이 인기 (Navidrome이 서빙) |
| **Readarr** | - | ✅ 유지 | 동일. 대체 불필요 |
| **Prowlarr** | - | ✅ 유지 | *arr 통합 인덱서 관리. 현재 표준 |

---

## ⬇️ 다운로드 클라이언트

| 기존 | 대체 | 상태 | 비고 |
|------|------|------|------|
| **qBittorrent** | - | ✅ 유지 | 여전히 최고 선택지. qBittorrent-nox (headless) + VueTorrent UI 조합 추천 |
| **SABnzbd** | **NZBGet** / **SABnzbd 유지** | ✅ 유지 | NZBGet이 빠르지만 개발 중단됨. SABnzbd가 현재도 안정적으로 유지 |
| **YoutubeDL** (웹UI) | **Metube** / **TubeArchivist** | ⚠️ 대체 고려 | Metube가 현재 가장 많이 쓰이는 yt-dlp 웹 프론트엔드. TubeArchivist는 YouTube 채널 아카이빙 특화 |
| **Nicotine+** | - | ✅ 유지 | Soulseek 클라이언트 자체가 틈새. 대체재 없음 |
| **OpenBooks** | - | ✅ 유지 | Library Genesis 다운로드 용도. 유지 |

---

## 🎞️ 미디어 처리

| 기존 | 대체 | 상태 | 비고 |
|------|------|------|------|
| **Tdarr** | **Unmanic** / **FileFlows** | ⚠️ 대체 고려 | Tdarr 자체는 강력하지만 무겁고 Node.js 기반 플러그인이 복잡함. **Unmanic**은 단순 파이프라인에 적합한 경량 대안. **FileFlows**는 설정 편의성으로 주목받는 신흥 대안 |

---

## 🌐 네트워크 / 보안

| 기존 | 대체 | 상태 | 비고 |
|------|------|------|------|
| **Pi-hole** | **AdGuard Home** | ⚠️ 대체 고려 | AdGuard Home이 현재 더 추천됨 — 단일 바이너리, DoH/DoT/DoQ 내장, 디바이스별 필터링 기본 지원. Pi-hole v6 (2025 말 출시)로 많이 개선됐으나 암호화 DNS는 여전히 외부 도구 필요 |
| **Cloudflare Tunnel** | - | ✅ 유지 | 포트 오픈 없이 외부 접근. 여전히 최고 선택지 |
| **Uptime Kuma** | - | ✅ 유지 | 헬스체크 모니터링. 대체 불필요 |
| **Tailscale** | - | ✅ 유지 | WireGuard 메시 VPN. 대체 불필요 |
| **SWAG** (Nginx + SSL) | **Caddy** / **Traefik** | ⚠️ 대체 고려 | SWAG 자체는 지금도 쓸 수 있지만: **Caddy**는 Caddyfile 문법이 간결하고 자동 HTTPS가 기본값. **Traefik**은 k3s 환경에서 라벨 기반 자동 라우팅으로 GitOps 친화적 — k3s라면 Traefik 추천 |
| **Authelia** | **Authentik** | ⚠️ 상황에 따라 | Authelia는 경량 SSO 게이트웨이로 여전히 유효. 다만 OIDC 토큰 발급, SAML, 유저 자체 관리 필요하면 **Authentik**으로 이전 고려. 홈랩 규모면 Authelia로 충분 |
| **LLDAP** | - | ✅ 유지 | 경량 LDAP. Authelia/Authentik 백엔드로 계속 유효 |
| **Guacamole** | - | ✅ 유지 | 브라우저 기반 RDP/VNC/SSH. 대체 불필요 |

---

## 📊 인프라 / 모니터링

| 기존 | 대체 | 상태 | 비고 |
|------|------|------|------|
| **Unraid** | - | ✅ 유지 | NAS OS. 대체 불필요 (Proxmox + TrueNAS도 선택지지만 목적이 다름) |
| **Grafana** | - | ✅ 유지 | 메트릭 대시보드 표준. 대체 불필요 |
| **InfluxDB** | **Prometheus + VictoriaMetrics** | ⚠️ 대체 고려 | k3s 환경이라면 `Prometheus + Grafana` 스택이 더 자연스러움. InfluxDB는 시계열 DB로 여전히 유효하나 k8s 생태계와 궁합은 Prometheus가 나음 |
| **Home Assistant** | - | ✅ 유지 | 홈 자동화 표준. 대체 불필요 |
| **Adminer** | - | ✅ 유지 | DB 웹 관리. 대체 불필요 (단순 목적엔 충분) |
| **Code-Server** | - | ✅ 유지 | 브라우저 VS Code. 대체 불필요 |
| **SWAG Dashboard** | - | ✅ 유지 | SWAG 쓴다면 그대로 |

---

## 📚 책 / 독서

| 기존 | 대체 | 상태 | 비고 |
|------|------|------|------|
| **Readarr** | - | ✅ 유지 | 위 *arr 스택과 동일 |
| **Readarr_audio** | - | ✅ 유지 | 오디오북 자동화. 유지 |
| **Calibre / Calibre-Web** | - | ✅ 유지 | 전자책 관리 표준. 대체 불필요 |
| **Audiobookshelf** | - | ✅ 유지 | 오디오북 + 팟캐스트 서버. 여전히 최고 선택지 |

---

## 🎮 기타

| 기존 | 대체 | 상태 | 비고 |
|------|------|------|------|
| **Mealie** | - | ✅ 유지 | 레시피 관리. 대체 불필요 |
| **Voyager** | - | ✅ 유지 | Lemmy 클라이언트. 대체 불필요 |
| **EmulatorJS** | - | ✅ 유지 | 브라우저 에뮬레이터. 대체 불필요 |

---

## 🗂️ *arr 확장 도구

| 앱 | 설명 | 대체 | 상태 |
|------|------|------|------|
| **Maintainerr** | 미디어 라이브러리 정리 자동화. 규칙 기반으로 안 본 콘텐츠 수집 → "Leaving Soon" 컬렉션 표시 → 자동 삭제. Radarr/Sonarr/Seerr 연동 | - | ✅ 유지 (v3.0부터 Jellyfin 지원 추가) |
| **Jackett** | 토렌트/Usenet 인덱서 프록시. *arr에 수동으로 API 키 복붙 필요 | **Prowlarr** | 🔴 대체 권장 |
| **Ombi** | 미디어 요청 관리 (Plex/Jellyfin/Emby 지원). Seerr보다 기능이 많지만 UI가 낡음 | **Seerr** | ⚠️ 대체 고려 |
| **NZBGet** | Usenet 다운로드 클라이언트 | **SABnzbd** | ⚠️ 대체 고려 (NZBGet 개발 중단) |
| **Transmission** | 경량 토렌트 클라이언트 | - | ✅ 유지 (경량 용도로 여전히 유효. *arr 스택엔 qBittorrent 선호) |

---

## 🔧 인프라 / 가상화

| 앱 | 설명 | 대체 | 상태 |
|------|------|------|------|
| **Portainer** | Docker/Swarm/k8s 컨테이너 웹 관리 UI | **Headlamp** (읽기전용) | ⚠️ **GitOps 충돌** — Portainer는 imperative(클릭) 관리라 Argo CD와 정반대. 손으로 만지면 drift 발생. 클러스터 뷰만 필요하면 Headlamp 권장 |
| **PBS** (Proxmox Backup Server) | Proxmox VM/LXC 증분 백업 서버 | - | ✅ 유지. Proxmox 생태계 표준 |
| **Pimox** (Pimox Cluster) | Raspberry Pi 위에서 돌리는 Proxmox 포트 | - | ✅ 유지 (ARM용 Proxmox. 틈새 용도) |
| **UniFi** | Ubiquiti 네트워크 장비 컨트롤러 (AP, 스위치, 라우터 관리) | - | ✅ 유지. 하드웨어 종속적 |
| **NetBoot** (netboot.xyz) | PXE 부팅 서버. 네트워크로 OS 설치 이미지 부팅 | - | ✅ 유지 |

---

## 🛠️ 생산성 / 유틸리티

| 앱 | 설명 | 대체 | 상태 |
|------|------|------|------|
| **Pingvin-Share** | WeTransfer 대체 셀프호스팅 파일 공유. 임시 링크 생성 | **Pingvin-Share X** | 🔴 대체 필수 |
| **StirlingPDF** | 서버사이드 PDF 편집 올인원 툴 (병합/분할/OCR/압축/변환 등 60종+). ilovepdf.com 대체 | **BentoPDF** (경량) | ✅ 유지 or ⚠️ 고려 |

> **Pingvin-Share**: 2025년 6월 원작자가 GitHub 아카이브 선언. **Pingvin-Share X**라는 커뮤니티 포크가 현재 유지보수 중이므로 이전 필요.  
> **StirlingPDF vs BentoPDF**: StirlingPDF는 서버사이드 처리로 Docker 이미지 ~1GB, 메모리 사용 큼. BentoPDF는 클라이언트사이드(브라우저) 처리라 서버 부하 없음 + 파일이 서버에 안 올라감. 단순 PDF 작업이면 BentoPDF 고려.

---

## 🟢 실제 배포 중 (k3s) — doc 누락분

> 위 표들은 미디어 중심 레퍼런스라 정작 **현재 k3s에 돌고 있는 앱 대부분이 빠져 있었다.** 아래가 실배포 현황.

| 앱 | 분류 | 대체/방향 | 상태 | 비고 |
|----|------|-----------|------|------|
| **Homepage** | 대시보드 | ← **Heimdall** | 🔴 대체 확정 | Heimdall 릴리스 정체. Homepage는 YAML 설정 + 서비스 위젯 다수로 GitOps 친화. **마이그레이션 진행** |
| **Vaultwarden** | 비밀번호 | - | ✅ 유지 | Bitwarden 호환 표준. 팀 공유/감사 필요 시 Passbolt |
| **Miniflux** | RSS | FreshRSS | ✅ 유지 | 경량·단일 바이너리. 다중 사용자 필요하면 FreshRSS |
| **Karakeep** | 북마크/읽을거리 | Linkwarden | ✅ 유지 | ⚠️ **Hoarder가 2025년 Karakeep으로 개명** — 옛 이름 태그 주의. AI 자동 태깅 |
| **Navidrome** | 음악 재생 | - | ✅ 유지 | Subsonic API 표준. 자동 수집은 별도(Lidarr, 위 *arr 참고) |
| **Komga + Suwayomi** | 만화 서버+다운로더 | Kavita | ✅ 유지 | 이미 "다운로더+라이브러리 공유" 패턴으로 배포됨 |
| **n8n** | 자동화 | Activepieces / Windmill | ✅ 유지 | 워크플로 자동화 표준 |
| **Anytype** | 노트/PKM | AppFlowy / SiYuan / Logseq | ✅ 유지 | 로컬 우선 |
| **Excalidraw** | 화이트보드 | tldraw | ✅ 유지 | 대체 불필요 |
| **Semaphore** | Ansible UI | AWX | ✅ 유지 | AWX는 무거움 — 홈랩이면 Semaphore가 적절 |
| **ntfy** | 푸시 알림 | Gotify | ✅ 유지 | ntfy가 더 모던(토픽, iOS) |
| **Netdata** | 실시간 모니터링 | - | ✅ 유지 | 장기 시계열은 InfluxDB→Prometheus 행 연계 |
| **Uptime-Kuma** | 헬스체크 | - | ✅ 유지 | 위 네트워크 섹션과 동일 |
| **Traefik** | 인그레스 | - | ✅ **적용 완료** | "SWAG→Traefik 고려"가 아니라 이미 사용 중 |

### 배포 검토 중 (미배포)

| 앱 | 판단 | 이유 |
|----|------|------|
| **PBS** (Proxmox Backup Server) | 👍 추천 | 손수 백업 스크립트 → VM/LXC 증분 백업 업그레이드. **Proxmox-side 작업**(이 repo의 GitOps 대상 아님) |
| **Home Assistant** | 조건부 | 스마트기기/자동화 대상 있으면 배포. 없으면 YAGNI |
| **Portainer** | 👎 비추 | 위 인프라 섹션 참고 — GitOps 충돌. Headlamp(읽기전용) 권장 |

---

## 🔴 즉시 대체 필수 요약

| 앱 | 이유 |
|------|------|
| **Overseerr** → **Seerr** | 2024년 유지보수 완전 종료. 보안 패치 없음 |
| **Plex** → **Jellyfin** | 2025년 외부 스트리밍 유료화. 셀프호스팅 철학과 불일치 |
| **Pingvin-Share** → **Pingvin-Share X** | 2025년 6월 원작자 아카이브 선언. 포크 버전으로 이전 |
| **Jackett** → **Prowlarr** | *arr 스택 쓴다면 Prowlarr이 표준. Jackett은 수동 API 키 복붙 필요 |
| **Heimdall** → **Homepage** | Heimdall 릴리스 정체. Homepage가 GitOps 친화 대시보드 표준 (마이그레이션 진행) |

## ⚠️ 상황 따라 대체 고려

| 앱 | 대체 | 이유 |
|------|------|------|
| **Pi-hole** | AdGuard Home | DoH/DoT 내장, 모던 UI, 디바이스별 필터 |
| **SWAG** | Traefik | k3s 환경에서 레이블 기반 자동 라우팅이 GitOps 친화적 |
| **Tautulli** | Jellystat | Plex → Jellyfin 이전 시 |
| **InfluxDB** | Prometheus | k3s 환경에서 더 자연스러운 스택 |
| **Tdarr** | Unmanic | 단순 파이프라인이면 Unmanic이 훨씬 가볍고 쉬움 |
| **Ombi** | Seerr | UI/UX 면에서 Seerr이 훨씬 모던, Ombi는 기능은 많지만 낡음 |
| **NZBGet** | SABnzbd | NZBGet 개발 중단, SABnzbd가 현재 유일한 선택지 |
| **StirlingPDF** | BentoPDF | 서버 리소스 절약 + 파일 서버 업로드 없는 클라이언트사이드 처리 |