# 공개 호스트 추가 자동화 — 현재 / 정석 / 마이그레이션 (실행 런북 포함)

> 배경: 공개 호스트(`*.<public-zone>`) 하나를 추가/이동하면 **세 시스템**을 손봐야 한다.
> ntfy 웹 컷오버(2026-06-21)에서 이 toil 이 드러나 정리한 설계 노트.
> 이 문서만 보고 마이그레이션을 그대로 실행할 수 있도록 각 단계에 런북(prereq → 적용 → 검증 → 롤백)을 붙였다.

## 현재 — 3개 시스템, 일부만 자동화

| 시스템 | 무엇 | 상태 |
|---|---|---|
| **homelab-gitops** (k8s manifest + IngressRoute + `DOMAIN_*` 토큰) | 앱 정의 | ✅ GitOps(ArgoCD) 자동 싱크 |
| **OpenWrt DNS** (homelab-network `ansible/host_vars/gateway.yml` `local_dns_overrides`) | LAN split-horizon (`*.<zone> → <node>`) | ⚠️ ansible 코드화이지만 **호스트당 한 줄 수기 리스트(현재 21줄, 전부 `→ 10.0.0.101`)** |
| **Cloudflare** (터널 ingress 규칙 + 공개 DNS CNAME) | 공개 엣지 | ❌ 대시보드/수기 API = **ad-hoc** (cloudflared 가 `TUNNEL_TOKEN` 토큰 모드 → ingress 규칙이 CF 대시보드에 있음) |

빠진 건 둘뿐: **Cloudflare 가 코드가 아님** + **세 개를 묶는 단일 진입점이 없음**.

> 토큰 SSOT: git-ignored `internal/tokens.env` + 라이브 `argocd-render-tokens` Secret 양쪽에 있어야 함.
> CF 토큰 권한 주의 — `cloudflare_ddns_api_token`(sops)은 **DNS:Edit 전용**이라 external-dns 가 재사용 가능하지만,
> 터널 ingress/생성엔 별도 **Tunnel:Edit** 토큰 필요 (`internal/cf-tunnel.env` 의 그 토큰).

---

## 0단계 (즉시, 의존성 0) — dnsmasq 21줄을 와일드카드 1줄로 붕괴

**가장 싸고 효과 큰 변경이자, 기존 마이그레이션 계획이 놓쳤던 부분.**

`local_dns_overrides` 의 `*.eli.kr` 항목 21개가 **전부 동일한 `10.0.0.101`** 을 가리킨다(vault, n8n,
kuma, jellyfin, comics, argocd, traefik, ...). NPM 은퇴 후 *모든* `*.eli.kr` 이 Traefik(.101) 한 곳으로
진입하므로, LAN 입장에서 호스트를 개별 나열할 이유가 없다.

- dnsmasq `address=/eli.kr/10.0.0.101` 은 zone + **모든 서브도메인**에 매치된다.
- public/internal 구분은 dnsmasq 가 아니라 **Cloudflare(공개 레코드 유무)** 가 한다 — LAN 해석은 무조건 .101.
  두 관심사가 섞여 21줄로 부풀어 있었다.
- 더 구체적인 항목이 most-specific 우선이므로, `*.eli.kr` 중 .101 이 아닌 예외가 생기면 **그 호스트만** 추가하면 된다.

이 변경으로 **마이그레이션 3단계(내부 DNS + external-dns 2nd 인스턴스)가 통째로 불필요해진다** — LAN toil 이
와일드카드 한 줄로 영구 소멸하기 때문. 새 호스트 cutover 시 dnsmasq 줄 추가가 영원히 사라진다.

### 런북 0 — 와일드카드 적용 (homelab-network)

**Before** (`ansible/host_vars/gateway.yml` → `local_dns_overrides`):
```yaml
local_dns_overrides:
  - "/eli.kr/::"
  - "/miner-eth/10.0.0.200"
  - "/miner-xrp/10.0.0.201"
  - "/miner-sol/10.0.0.202"
  - "/vault.eli.kr/10.0.0.101"   # ← 이하 21줄 전부 → 10.0.0.101
  - "/n8n.eli.kr/10.0.0.101"
  # ... (kuma/jellyfin/immich/proxmox/openwrt/kvm/rss/draw/comics/comics-admin/
  #      book/semaphore/heimdall/beszel/traefik/argocd/anytype/keep/ntfy)
```

**After** (21줄 → 1줄):
```yaml
local_dns_overrides:
  - "/eli.kr/::"             # AAAA 억제 (Traefik IPv4-only 레이스 방지) — 유지
  - "/eli.kr/10.0.0.101"     # ★ 모든 *.eli.kr → Traefik. 위 21개 개별 항목을 대체
  - "/miner-eth/10.0.0.200"  # eli.kr 아님 → 개별 유지
  - "/miner-xrp/10.0.0.201"
  - "/miner-sol/10.0.0.202"
```

**적용 / 검증 / 롤백**:
```sh
cd "$HOME/personal/homelab-network/ansible"
# 1) drift 확인 — dns 항목만 changed 로 떠야 함 (firewall/pbr/zapret 변화 0)
ansible-playbook -i inventory.yml playbook-apply.yml --check --diff --limit openwrt --tags dns
# 2) 적용
ansible-playbook -i inventory.yml playbook-apply.yml --diff --limit openwrt --tags dns
# 3) 검증 — 라우터에서 와일드카드 + 임의 신규 호스트가 .101 로 해석되는지
ssh root@10.0.0.1 "uci -q get dhcp.@dnsmasq[0].address"          # 5개 항목만 남아야 함
dig +short @10.0.0.1 vault.eli.kr        # → 10.0.0.101
dig +short @10.0.0.1 anything-new.eli.kr # → 10.0.0.101 (개별 항목 없이도)
dig +short @10.0.0.1 vault.eli.kr AAAA   # → (빈 응답: :: 억제 동작)
# 롤백: git revert 후 동일 apply. (dns.yml 은 set 비교로 idempotent — 안전)
```

> ⚠️ 전제: `*.eli.kr` 중 LAN 에서 .101 이 아닌 곳으로 가야 하는 호스트가 없어야 한다. 현재 전부 .101(맞음).
> 예외 발생 시 그 호스트만 더 구체적 항목으로 추가하면 most-specific 우선으로 와일드카드를 덮는다.

---

## 정석 (canonical) — 단일 선언 → 컨트롤러가 reconcile

원칙: **서비스는 한 곳(IngressRoute)에서 선언적으로 정의하고, 공개 DNS·터널은 컨트롤러가 그걸 보고 자동 생성한다.**
명령형 스크립트도, 손으로 치는 API 도, Ansible 로 클라우드 DNS 미는 것도 정석이 아님.

| 계층 | 정석 도구 | 비고 |
|---|---|---|
| k8s 서비스/라우트 | GitOps (이미 정석) — IngressRoute 가 단일 선언 | — |
| 공개 DNS 레코드 | **external-dns** + Cloudflare provider, `--source=traefik-proxy` | IngressRoute watch → CF DNS 자동 생성/삭제. **1단계** |
| 터널 ingress 규칙 | cloudflared **`credentials-file` 모드 + in-cluster ConfigMap(git)** | 토큰 모드 탈출. Traefik 이 호스트 라우팅을 다 하므로 **catch-all 한 줄**로 거의 고정. **2단계** |
| LAN split-horizon | **0단계 와일드카드로 해결됨** | 내부 DNS/external-dns 2nd 인스턴스 **불필요** |

최종 그림:

> IngressRoute 하나 선언(공개면 `publish` 표식) → external-dns 가 CF 공개 DNS 자동 기록 →
> 터널은 catch-all 로 전부 Traefik 에 전달(거의 안 바뀜) → LAN 은 와일드카드로 이미 .101.
> **호스트 추가가 k8s manifest 단 한 곳으로 수렴. CF DNS·LAN 수기 전부 소멸.**

### public/internal 게이트가 어디로 옮겨가는가 (중요)

- 현재: "공개 CF DNS 레코드의 부재" 가 internal-only 게이트 (`argocd`/`traefik`/`semaphore`/`comics-admin` 등).
- 마이그레이션 후: **external-dns 가 레코드 생성을 담당** → 게이트 = "external-dns 가 그 IngressRoute 에 레코드를 만드냐".
  - **opt-out 방식(권장)**: 기본 전부 생성, internal-only IngressRoute 에만
    `external-dns.alpha.kubernetes.io/controller: none` annotation → 레코드 미생성 → 공개 NXDOMAIN 유지.
  - 터널을 `*.eli.kr` catch-all 한 줄로 둬도, 공개 레코드가 없으면 외부에서 그 호스트로 CF 엣지에 도달 자체가 불가 → 게이트 유지.
- 결과: internal/public 판단이 **IngressRoute 의 annotation 한 개**로 코드화됨 (현재의 암묵적 "대시보드에 CNAME 안 만듦" 규율을 대체).

---

## 두 학파 / 도구 위치

- **컨트롤러/오퍼레이터 학파** (external-dns + 터널 config-as-code): k8s-네이티브 GitOps 정석. **이 환경에 가장 맞음.**
- **Terraform 학파**: "Cloudflare/인프라를 IaC 로" 의 정석. 맞지만 별도 컨트롤 플레인이 생기고, k8s-앞단 서비스의 "단일 선언" 목표엔 컨트롤러보다 덜 우아.
- **Ansible/Semaphore**: **OpenWrt 라우터 장비 자체**(방화벽/PBR/wg/패키지) 관리엔 정석. 클라우드 DNS·터널을 Semaphore 로 모는 건 external-dns 가 하는 일을 손으로 재구현하는 셈 — 정석 아님. → **Semaphore 는 라우터 장비 관리에만** 남긴다.

---

## 마이그레이션 순서 (개정)

호밤 규모(공개 호스트 ~15개, 변경 드묾)에선 풀 스택이 과할 수 있으나, 목표가 "문서만 보고 자동 진행"이므로
각 단계가 **독립적으로 가치 있고 되돌릴 수 있게** 쪼갰다.

| # | 단계 | 제거하는 toil | 의존성 | ROI |
|---|---|---|---|---|
| **0** | dnsmasq 와일드카드 | LAN 수기 리스트 (영구) | 없음 | ★★★ (즉시) |
| **1** | external-dns (CF) | 공개 DNS 수기 | DNS:Edit 토큰 | ★★★ |
| **2** | 터널 config-as-code | 터널 ingress 수기 (대시보드) | Tunnel cred | ★★ |
| **3 (선택)** | CF Access — internal=mTLS / public=open | wg1 의존(웹 UI 한정), 원격 접근 마찰 | Tunnel(2 권장) | ★★ (원격 필요 시) |
| ~~(구)3~~ | ~~내부 DNS + external-dns 2nd~~ | — | — | **0단계로 폐기** |

순서 권고: **0 → 1 → 2**. 0 은 지금 바로. 1 은 효과가 가장 크고 위험이 낮음(upsert-only 로 시작). 2 는 변경이 드물어 후순위이며, 안 해도 시스템은 완결됨.

---

## 런북 1 — external-dns (Cloudflare) 도입

**목표**: IngressRoute 의 `Host()` 를 watch → `*.eli.kr` 공개 CF DNS 레코드 자동 생성/관리. 공개 DNS 수기 소멸.

### 1.1 Prereq
- CF API 토큰: `Zone:DNS:Edit` (zone=eli.kr). 기존 `cloudflare_ddns_api_token` 재사용 가능 → 클러스터엔 **SealedSecret 로 봉인**해 주입.
- 레코드 타깃: `*.eli.kr` 은 CNAME → `<tunnel-id>.cfargotunnel.com` (현재 ntfy 등에서 쓰는 그 터널 도메인). external-dns `--target` 으로 고정하거나 IngressRoute annotation 으로 지정.

### 1.2 매니페스트 (app-of-apps 패턴 — `infra/external-dns/` + `argocd/apps/external-dns.yaml`)
`infra/external-dns/` 에 kustomize 로:
- `namespace.yaml` (`external-dns`)
- `sealedsecret.yaml` — `cloudflare-api-token` (key: `CF_API_TOKEN`), `kubeseal` 로 봉인:
  ```sh
  kubectl create secret generic cloudflare-api-token -n external-dns \
    --from-literal=CF_API_TOKEN="$(grep -m1 cloudflare_ddns_api_token internal/tokens.env | cut -d= -f2-)" \
    --dry-run=client -o yaml \
  | kubeseal --format yaml --controller-namespace sealed-secrets > infra/external-dns/sealedsecret.yaml
  ```
- `deployment.yaml` — `registry.k8s.io/external-dns/external-dns` (버전은 `versions.yaml` SSOT 에 핀), args:
  ```
  --source=traefik-proxy           # IngressRoute(CRD) 를 소스로
  --provider=cloudflare
  --domain-filter=eli.kr           # 이 zone 만 건드림 (안전벽)
  --policy=upsert-only             # ★ 시작은 삭제 금지(기존 수기 레코드 보호). 안정화 후 sync 로 승격
  --txt-owner-id=homelab-k3s       # 소유권 TXT — 다른 관리주체 레코드와 충돌 방지
  --registry=txt
  --cloudflare-proxied=false       # 터널 경유이므로 회색 구름(프록시 off). 필요시 true
  --interval=1m
  ```
  - `CF_API_TOKEN` 은 `envFrom: secretRef: cloudflare-api-token`.
  - RBAC: `traefik.io` IngressRoute `get/list/watch` ClusterRole + binding 추가.
- `kustomization.yaml` (리소스 묶음, cloudflared 패턴 참고)

`argocd/apps/external-dns.yaml` — Application, `sync-wave: "2"` (sealed-secrets 이후, cloudflared 와 동급).

### 1.3 IngressRoute 표식 (한 번만)
- **internal-only** 호스트(argocd/traefik/semaphore/comics-admin/heimdall/beszel)의 IngressRoute 에:
  ```yaml
  metadata:
    annotations:
      external-dns.alpha.kubernetes.io/controller: none   # 공개 레코드 미생성 = NXDOMAIN 게이트
  ```
- 공개 호스트는 표식 불필요(기본 생성). CNAME 타깃 고정이 필요하면:
  ```yaml
      external-dns.alpha.kubernetes.io/target: "<tunnel-id>.cfargotunnel.com"
  ```

### 1.4 검증 / 롤백
```sh
# 적용은 git push → ArgoCD 자동 싱크. 로그로 동작 확인:
kubectl -n external-dns logs deploy/external-dns | grep -iE 'CREATE|UPDATE|skipping'
# 공개 호스트 레코드 생성 확인 / internal 은 미생성 확인:
dig +short vault.eli.kr @1.1.1.1          # → 레코드 존재
dig +short argocd.eli.kr @1.1.1.1         # → NXDOMAIN (게이트 유지)
# 롤백: argocd/apps/external-dns.yaml 제거(git revert) → prune 로 컨트롤러 삭제.
#       upsert-only 라 기존 레코드는 그대로 남음(파괴 없음). 가장 안전한 진입.
```

> 승격: 며칠간 `upsert-only` 로 안정 확인 후 `--policy=sync` 로 바꾸면 IngressRoute 삭제 시 CF 레코드도 자동 삭제(완전 reconcile). `--txt-owner-id` 덕에 external-dns 가 만든 것만 지운다.

---

## 런북 2 — 터널 config-as-code (토큰 모드 → credentials-file)

**목표**: `infra/cloudflared/deployment.yaml` 의 `TUNNEL_TOKEN`(ingress 규칙이 CF 대시보드에 있음) 탈출 →
git 의 `config.yaml`(ConfigMap)이 ingress SSOT. Traefik 이 호스트 라우팅을 하므로 **catch-all 한 줄**.

### 2.1 Prereq
- 터널 자격증명 JSON (`AccountTag`/`TunnelID`/`TunnelSecret`) — 기존 터널 것 사용. `cloudflared tunnel token` 역디코드 또는 CF 대시보드/`~/.cloudflared/<id>.json`. `internal/` 에 보관.
- Traefik 서비스 in-cluster DNS 이름 (예: `traefik.kube-system.svc:443`) 및 origin TLS 옵션.

### 2.2 변경 내용
1) **credentials SealedSecret** (`cloudflared-credentials`, key `credentials.json`):
   ```sh
   kubectl create secret generic cloudflared-credentials -n cloudflared \
     --from-file=credentials.json=internal/<tunnel-id>.json \
     --dry-run=client -o yaml \
   | kubeseal --format yaml --controller-namespace sealed-secrets > infra/cloudflared/sealedsecret-credentials.yaml
   ```
2) **ConfigMap `config.yaml`** (`infra/cloudflared/configmap.yaml`, git SSOT — catch-all):
   ```yaml
   tunnel: <tunnel-id>
   credentials-file: /etc/cloudflared/creds/credentials.json
   ingress:
     # 모든 *.eli.kr → Traefik. 호스트별 분기는 Traefik IngressRoute 가 담당.
     # internal/public 게이트는 external-dns(레코드 유무)가 담당하므로 여기선 분기 불필요.
     - service: https://traefik.kube-system.svc:443
       originRequest:
         originServerName: ""   # SNI 전달; 필요시 와일드카드 origin 검증 설정
     # (anytype 등 비-HTTP 는 별도 TCP/UDP 규칙이 필요하면 여기 추가)
   ```
   > catch-all 이라 호스트 추가 시 이 파일은 **안 바뀜**. 터널 ingress toil 이 사실상 0 이 됨.
3) **deployment.yaml** 수정:
   - `envFrom: cloudflared-token` 제거.
   - args 를 `run --config /etc/cloudflared/config.yaml <tunnel-id>` 형태로.
   - volumeMounts: ConfigMap(`config.yaml`) + Secret(`credentials.json`).
   - 구 `cloudflared-token` SealedSecret 은 마지막에 prune.
4) `kustomization.yaml` 에 `configmap.yaml`, `sealedsecret-credentials.yaml` 추가.

### 2.3 검증 / 롤백
```sh
kubectl -n cloudflared logs deploy/cloudflared | grep -iE 'Registered tunnel|config|error'
kubectl -n cloudflared get deploy cloudflared -o jsonpath='{.status.readyReplicas}'  # = 2
curl -sI https://vault.eli.kr | head -1   # 외부 경로 200/301 (CF→터널→Traefik)
# 롤백: deployment.yaml/kustomization 을 git revert → 토큰 모드로 즉시 복귀.
#       구 cloudflared-token SealedSecret 은 2.3 검증 통과 전까지 삭제 금지.
```

> ⚠️ replicas=2, `maxUnavailable: 0` 유지 — 롤아웃 중 엣지 무중단(현 deployment 주석 참고). credentials 모드도 동일 터널이라 CF-side 변경 불필요.

---

## 런북 3 (선택) — CF Access: VPN 없이 내 기기만 직통 (mTLS, default-deny)

**목표**: internal-only 호스트(argocd/traefik/semaphore/comics-admin/heimdall/beszel)를 **VPN(wg1) 없이**
어디서든, **CF 클라이언트 인증서가 깔린 내 기기에서만** 접근. 공개 호스트는 그대로 오픈.

### 자세: default-deny (전부 열고 닫기 ❌ → 전부 닫고 열기 ✅)
CF Access 는 **most-specific 매칭**. catch-all 을 잠그고 공개 호스트만 예외로 연다:
```
*.eli.kr        → [기본 Access app] require: valid client certificate   ← 기본 잠금
vault.eli.kr    → [예외 app] Bypass / Everyone                          ← 명시적 공개
comics.eli.kr · book · ntfy · rss · draw · keep · anytype · ...  → Bypass
```
→ 새 호스트는 자동으로 잠긴 상태(catch-all). 공개 전환은 **Bypass 예외 추가**라는 의식적 행위로만 = fail-safe.

### 3.1 Prereq
- CF Zero Trust 활성화 (무료 50 user). `internal/` 에 org team domain 기록.
- internal 호스트를 **공개 등록**해야 함(게이트가 NXDOMAIN → Access 로 이동): 1단계 external-dns 에서
  해당 IngressRoute 의 `external-dns.alpha.kubernetes.io/controller: none` **제거** → 공개 레코드 생성되게.
  (잠금은 이제 Access mTLS 가 담당. 도달 가능하지만 인증서 없으면 CF 엣지에서 TLS 단계 차단)

### 3.2 mTLS 설정 (CF Zero Trust 대시보드 / API)
1. **Zero Trust → Settings → Network → Mutual TLS**: root CA 등록(자체 CA 한 개 생성 → CF 에 public cert 업로드). CA 키는 `internal/` SOPS 봉인.
2. CA 로 **기기별 client cert 발급**(노트북/데스크톱/태블릿). 기기에 설치:
   - macOS/iOS: `.p12` 를 키체인/구성 프로파일로.
   - Android Chrome: client cert 지원 빈약 → 폰 접근 필요한 호스트만 **OTP/WARP fallback 정책**(아래).
3. **Access → Applications**:
   - **기본 앱**: domain `*.eli.kr`, policy `Action: Allow`, include `Valid Certificate`. (catch-all 잠금)
   - **공개 예외 앱**: 각 공개 호스트(`vault.eli.kr` 등), policy `Action: Bypass`, include `Everyone`.
   - **모바일 fallback**(선택): 폰에서 쓸 internal 호스트는 별도 앱에 `Valid Certificate **OR** Emails(내 이메일 OTP)`.

> 코드화: Access app/policy 는 CF API 객체라 정석은 **Terraform(cloudflare provider)** 로 `internal/` 에 둠.
> 대시보드 수기로 시작해도 되나, 호스트가 늘면 Terraform 으로 승격(이 repo 가 아닌 homelab-network/oracle 패턴 재사용).

### 3.3 검증 / 롤백
```sh
# 인증서 있는 기기(외부망):
curl --cert client.crt --key client.key -sI https://argocd.eli.kr | head -1   # 200/302
# 인증서 없는 요청 → CF 엣지에서 거부(앱/터널 도달 안 함):
curl -sI https://argocd.eli.kr | head -1                                       # 403/cert required
# 공개 호스트는 인증서 없이도:
curl -sI https://vault.eli.kr | head -1                                        # 200/301
# 롤백: 기본 앱(catch-all) 삭제 → 즉시 무인증. + 해당 IngressRoute 에 controller:none 재부여
#       → external-dns 가 공개 레코드 제거 → NXDOMAIN(구 모델)로 복귀.
```

### 3.4 주의 (당신 셋업 특이점)
- **LAN 은 mTLS 우회.** 와일드카드 단축(`*.eli.kr → .101`) 때문에 LAN 클라이언트는 CF 엣지를 안 거침 →
  Access 검문 없음. = mTLS 는 **외부 경로만** 보호(LAN 신뢰 전제, 의도된 동작).
- **wg1 은 존속.** mTLS 는 웹 UI(HTTP)용. SSH·비-HTTP·네트워크 레벨 접근은 wg1 이 계속 담당. 역할 분담.
- internal 을 외부 노출하는 **순수 이득 = "VPN 없이 내 기기로 접근"**. 그게 불필요하면 이 단계를 건너뛰고
  NXDOMAIN + wg1(이미 default-deny)을 유지하는 게 더 lazy.

## 최종 상태 / 불변식 (마이그레이션 완료 후 "호스트 1개 추가")

| 작업 | 누가 |
|---|---|
| `workloads/<svc>/ingressroute.yaml` + `${SECRET:DOMAIN_<SVC>}` 토큰 추가, push | 사람 (한 곳) |
| 공개 CF DNS 레코드 | external-dns 자동 (internal 이면 `controller: none` 한 줄) |
| LAN 해석 (`→ 10.0.0.101`) | 와일드카드가 이미 처리 — **무작업** |
| 터널 ingress | catch-all 이 이미 처리 — **무작업** |
| 접근 제어 (3단계 도입 시) | 기본 catch-all mTLS 가 자동 잠금 — 공개로 열 때만 Bypass 예외 1개 추가 |

→ **공개 호스트 추가가 IngressRoute 단일 선언으로 수렴.** CF DNS·LAN·터널 수기 전부 소멸.

## 중간 단계 (정석 전, 더 미루고 싶을 때의 lazy 대안)

0단계만 적용하고 1·2 를 미룬다면: `internal/cf-tunnel.env`+`cloudflare_ddns_api_token` 을 재사용하는
래퍼 한 개(`add-public-host <host>`)가 CF DNS + 터널 ingress 를 한 번에 처리(LAN 은 와일드카드라 빠짐).
50줄, 새 의존성 0. 단 SSOT 정합성을 위해 repo 선언 → reconcile 형태로 둘 것. (1단계 external-dns 가 이걸 대체)
