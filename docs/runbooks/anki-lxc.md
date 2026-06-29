# Runbook: Anki LXC (AnkiConnect + self-hosted sync server)

Always-on Anki host for the `english-quest` n8n workflow. Runs two systemd services on one
unprivileged Proxmox LXC: `anki-headless` (AnkiConnect HTTP API on :8765) and `anki-syncserver`
(:27701). k3s pods reach AnkiConnect by LAN IP — no ArgoCD, no cluster involvement.

> See [spec-anki-lxc.md](../../_bmad-output/implementation-artifacts/spec-anki-lxc.md) for design
> rationale. See `versions.yaml` (repo root) for the pinned Anki version.

---

## 0. Prerequisites & versions

- Proxmox host: `${SECRET:HOST_PROXMOX}`
- **Pinned Anki version**: see `versions.yaml → anki.version`. Server and ALL clients (desktop,
  phone) MUST be on the same version — sync protocol is version-sensitive.
- AnkiConnect add-on ID: `2055492159`
- LXC static IP: reserve in OpenWrt DHCP leases (same pattern as k3s nodes).

---

## 1. Create the LXC

On the Proxmox host UI or CLI:

```sh
# Download Ubuntu 24.04 template if not present:
pveam update && pveam download local ubuntu-24.04-standard_24.04-2_amd64.tar.zst

# Create unprivileged LXC (adjust VMID / IP to your reserved values):
pct create 210 local:vztmpl/ubuntu-24.04-standard_24.04-2_amd64.tar.zst \
  --hostname anki \
  --cores 2 \
  --memory 2048 \
  --rootfs local-lvm:8 \
  --net0 name=eth0,bridge=vmbr1,ip=${SECRET:IP_ANKI_LXC}/24,gw=${SECRET:IP_LAN_GATEWAY} \
  --unprivileged 1 \
  --onboot 1 \
  --start 1

# Confirm it's running:
pct status 210
```

Reserve `${SECRET:IP_ANKI_LXC}` in OpenWrt: **Network → DHCP and DNS → Static Leases**.

---

## 2. Install system dependencies

```sh
pct exec 210 -- bash -c '
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y xvfb libxcb1 libxkbcommon0 libdbus-1-3 libxi6 \
    libxrender1 libxrandr2 libgl1 libpulse0 libglib2.0-0 \
    wget curl ca-certificates
'
```

---

## 3. Install Anki at the pinned version

```sh
# Confirm the pinned version from versions.yaml before running:
ANKI_VERSION="25.02.7"   # MUST match versions.yaml anki.version and all client devices

pct exec 210 -- bash -c "
  cd /tmp
  wget -q https://github.com/ankitects/anki/releases/download/${ANKI_VERSION}/anki-${ANKI_VERSION}-linux-qt6.tar.zst
  tar --use-compress-program=unzstd -xf anki-${ANKI_VERSION}-linux-qt6.tar.zst
  cd anki-${ANKI_VERSION}-linux-qt6
  ./install.sh
  anki --version   # verify
"
```

> **Sync protocol warning:** Anki's sync format changed across releases. A server/client version
> mismatch throws "sync protocol mismatch" and blocks all device syncs. This is the most likely
> operational failure — always bump server + all clients together.

---

## 4. Install AnkiConnect add-on

AnkiConnect must be placed in the add-ons directory before first launch:

```sh
ADDON_ID="2055492159"

pct exec 210 -- bash -c "
  mkdir -p /root/.local/share/Anki2/addons21/${ADDON_ID}

  cat > /root/.local/share/Anki2/addons21/${ADDON_ID}/meta.json <<'EOF'
{
  \"disabled\": false,
  \"mod\": 0,
  \"name\": \"AnkiConnect\",
  \"conflicts\": [],
  \"max_point_version\": 0,
  \"min_point_version\": 0,
  \"branch_index\": 0,
  \"update_enabled\": true
}
EOF
"

# Download the add-on code (adjust if offline):
pct exec 210 -- bash -c "
  cd /root/.local/share/Anki2/addons21/${ADDON_ID}
  wget -q 'https://ankiweb.net/shared/download/${ADDON_ID}?v=1' -O anki21.zip
  unzip -q anki21.zip
  rm anki21.zip
"
```

---

## 5. Configure AnkiConnect

```sh
pct exec 210 -- bash -c "
  ADDON_DIR=/root/.local/share/Anki2/addons21/2055492159
  mkdir -p \$ADDON_DIR

  cat > \$ADDON_DIR/config.json <<'EOCFG'
{
  \"apiKey\": \"${SECRET:ANKI_API_KEY}\",
  \"apiLogPath\": null,
  \"ignoreOriginList\": [],
  \"webBindAddress\": \"0.0.0.0\",
  \"webBindPort\": 8765,
  \"webCorsOriginList\": [\"http://localhost\"]
}
EOCFG
"
```

> `webCorsOriginList` is left at default (`http://localhost`). n8n is a non-browser caller — it
> sends no `Origin` header, so CORS is not exercised. Expanding this list is only needed for
> browser-based callers.

---

## 6. Create systemd units

### 6a. `anki-syncserver.service`

```sh
pct exec 210 -- bash -c "
cat > /etc/systemd/system/anki-syncserver.service <<'EOF'
[Unit]
Description=Anki self-hosted sync server
After=network.target

[Service]
Type=simple
User=root
Environment=SYNC_USER1=${SECRET:ANKI_SYNC_USER}
Environment=SYNC_BASE=/var/lib/anki-sync
Environment=SYNC_PORT=27701
ExecStart=/usr/local/bin/anki --syncserver
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

mkdir -p /var/lib/anki-sync
systemctl daemon-reload
systemctl enable --now anki-syncserver
"
```

`SYNC_USER1` format: `username:password` (plaintext in the unit env — kept in the git-ignored
`rendered/` path; never committed in clear text).

### 6b. `anki-headless.service`

```sh
pct exec 210 -- bash -c "
cat > /etc/systemd/system/anki-headless.service <<'EOF'
[Unit]
Description=Anki headless (AnkiConnect :8765)
After=network.target xvfb.service anki-syncserver.service
Requires=xvfb.service

[Service]
Type=simple
User=root
Environment=DISPLAY=:99
Environment=HOME=/root
Environment=QTWEBENGINE_CHROMIUM_FLAGS=--no-sandbox
ExecStart=/usr/local/bin/anki
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now anki-headless
"
```

> **Why Xvfb:** AnkiConnect serves through Anki's Qt webview, which requires a real (virtual) X
> display to initialise reliably. `QT_QPA_PLATFORM=offscreen` can leave the API half-initialised.

### 6c. `anki-headless-restart.timer` (12-hourly at 03:00 / 15:00 KST)

```sh
pct exec 210 -- bash -c "
cat > /etc/systemd/system/anki-headless-restart.service <<'EOF'
[Unit]
Description=Restart anki-headless to flush memory growth

[Service]
Type=oneshot
ExecStart=/bin/systemctl restart anki-headless
EOF

cat > /etc/systemd/system/anki-headless-restart.timer <<'EOF'
[Unit]
Description=Restart anki-headless every 12h at 03:00 and 15:00 KST

[Timer]
OnCalendar=*-*-* 03,15:00:00
TimeZone=Asia/Seoul
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now anki-headless-restart.timer
"
```

Timer fires at 03:00 and 15:00 KST — deliberately offset from the 06:00 english-quest workflow
window. Anki is freshly restarted and stable (~3h uptime) when the daily card-add runs.

---

## 7. Configure Anki client → self-hosted sync

Inside the LXC, launch Anki once with a display to set the custom sync endpoint:

```sh
# On the LXC console (or via xterm from Proxmox):
DISPLAY=:99 anki &
# Preferences → Syncing → Self-hosted sync server
# URL: http://127.0.0.1:27701/
# Media URL: http://127.0.0.1:27701/
```

Or set via Anki's prefs file directly (v24.x+):

```sh
pct exec 210 -- bash -c "
  python3 -c \"
import json, pathlib
p = pathlib.Path('/root/.local/share/Anki2/prefs21.json')
d = json.loads(p.read_text()) if p.exists() else {}
d['syncEndpoint'] = 'http://127.0.0.1:27701/'
d['syncMediaEndpoint'] = 'http://127.0.0.1:27701/media'
p.write_text(json.dumps(d))
\"
"
```

---

## 8. One-time collection migration

> Order matters: Upload from the device with the freshest collection, then Download on all others.
> Never initialise an empty collection on the server and sync — that destroys data.

1. **Desktop (source of truth):** do a final AnkiWeb sync to make sure nothing is pending.
2. **Desktop:** Preferences → Syncing → Self-hosted sync server → enter `http://${SECRET:IP_ANKI_LXC}:27701/` → OK.
3. **Desktop:** Tools → Sync (or Ctrl+Y) → when prompted choose **Upload** → your full collection goes to the LXC sync server.
4. **Phone (AnkiDroid):** Settings → Advanced → Custom sync server → `http://${SECRET:IP_ANKI_LXC}:27701/` → sync → choose **Download**.
5. **Phone (AnkiMobile/iOS):** Preferences → Sync → custom sync URL → same URL → Download.
6. **LXC client** (step 7 above): sync → Download (it now pulls from the local syncserver at 127.0.0.1).

If "Download" is chosen by mistake on desktop before Upload: the server is empty and overwrites the
desktop. Recovery: re-restore from the last AnkiWeb backup, then redo from step 1.

---

## 9. Verify

```sh
# From a k3s node or pod (replace IP and key):
curl -s http://${SECRET:IP_ANKI_LXC}:8765 \
  -d '{"action":"version","version":6,"key":"${SECRET:ANKI_API_KEY}"}'
# Expected: {"result":6,"error":null}

curl -s http://${SECRET:IP_ANKI_LXC}:8765 \
  -d '{"action":"deckNames","version":6,"key":"${SECRET:ANKI_API_KEY}"}'
# Expected: {"result":["Default","...your decks..."],"error":null}

# On the LXC:
systemctl is-active anki-headless anki-syncserver
# Expected: active\nactive

systemctl list-timers | grep anki
# Expected: anki-headless-restart.timer — next: 03:00:00 or 15:00:00 KST
```

---

## 10. Backup

Backup = Proxmox LXC snapshot/backup (the Anki collection lives in the LXC rootfs at
`/root/.local/share/Anki2/`). Configure in Proxmox Backup Server alongside the existing k3s VM
backups — reference from [bare-metal-recovery.md](bare-metal-recovery.md) for context on the
backup/restore pattern.

No k8s backup-cronjob. No additional tooling needed.

---

## 11. AnkiWeb fallback

If self-hosted sync proves problematic, switch all clients back to AnkiWeb:

1. Disable `anki-syncserver`: `systemctl disable --now anki-syncserver`
2. On each client: Preferences → Syncing → clear custom sync URL → sync normally to AnkiWeb.
3. The LXC `anki-headless` + AnkiConnect + the n8n integration are **unchanged** — only the sync
   endpoint differs.

---

## 12. Secrets reference

| Secret token | Description |
|---|---|
| `${SECRET:HOST_PROXMOX}` | Proxmox host (matches ansible/README.md convention) |
| `${SECRET:IP_ANKI_LXC}` | Reserved LAN IP for the LXC (OpenWrt DHCP lease) |
| `${SECRET:IP_LAN_GATEWAY}` | LAN gateway (same as k3s nodes) |
| `${SECRET:ANKI_API_KEY}` | AnkiConnect `apiKey` — non-empty, shared with n8n env |
| `${SECRET:ANKI_SYNC_USER}` | Sync server credential: `user:password` format |

Real values live in the git-ignored `rendered/` output only (follow repo tokenization convention).
