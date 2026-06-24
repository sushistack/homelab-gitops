---
title: 'Quarterly playlist lifecycle manager (music-curator)'
type: 'feature'
created: '2026-06-24'
status: 'done'
baseline_commit: '4be33dad540d2a0e4177af48108e4da69a17370c'
context:
  - '{project-root}/workloads/navidrome/'
  - '{project-root}/workloads/lidarr/'
  - '{project-root}/workloads/komga/kustomization.yaml'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** Navidrome playlists are managed by hand. There is no automated pipeline that discovers new music from Last.fm, curates a rolling quarterly playlist, or archives the year's highlights.

**Approach:** Deploy a new `music-curator` workload — a single long-lived Python Deployment with APScheduler (not a CronJob) that runs three scheduled jobs: weekly Last.fm discovery → Navidrome playlist add + Lidarr artist import, quarterly archive (retain only starred songs), and annual best-of playlist generation. No custom image build — uses the `uv` base image with a ConfigMap-mounted script with inline dependency declarations.

## Boundaries & Constraints

**Always:**
- Images digest-pinned (`@sha256`) with re-resolve comment + date.
- Deployment: resources requests+limits, TZ=Asia/Seoul, strategy: Recreate (single scheduler instance).
- Secrets only as SealedSecrets (placeholder + kubeseal header). API keys: ND password, Lidarr API key, Last.fm API key + secret.
- "Delete" = unstarred songs at quarterly archive → remove from playlist AND delete track file via Lidarr (track level, not album level). **Grace period: songs added to the playlist within the last 4 weeks are skipped at archive time** — they carry over to the next quarter's playlist unchanged (starred or not).
- Track file deletion via Lidarr: use `GET /api/v1/artist` (managed library, returns internal Lidarr IDs) — NOT `/api/v1/artist/lookup` (returns MusicBrainz data, no internal `id`). Match by `artistName` case-insensitive, then `GET /api/v1/trackFile?artistId={id}`, match path, `DELETE /api/v1/trackFile/{id}`.
- Current quarter playlist name derived from wall-clock date: `YYYY-Q{1-4}`. Created lazily on first discovery run.
- Lidarr artist add: only if artist has zero results in Navidrome search. Never re-add if already monitored.
- Last.fm API errors (429, network timeout, artist not found): skip that artist and continue the loop — never abort the whole weekly job. Log skipped artists at WARNING level.
- Duplicate prevention: check existing playlist song IDs via Subsonic API before adding; skip already-present IDs.
- Workload lives in its own namespace `music-curator`, not `lidarr`.
- No Ingress, no Service — scheduler only; no HTTP endpoint exposed.
- Probes: startupProbe exec `test -f /tmp/started` (script writes this file after APScheduler initialises); no readiness/liveness needed (Recreate + restart-policy is sufficient).

**Ask First:**
- Any change to the quarterly boundary dates (currently Jan 1 / Apr 1 / Jul 1 / Oct 1).
- Changing Last.fm discovery depth (default: recent 100 tracks → unique artists → 5 similar artists each → top 5 tracks each = ~125 candidates/week).

**Never:**
- No CronJob (cold-start noise on mini PC).
- No PVC / SQLite state — all state derived from live Navidrome playlist + star API queries.
- No file tag modification (risk of Lidarr tag overwrites).
- No plaintext secrets. No `:latest`/floating tags.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Artist already in Navidrome | Weekly discovery, Navidrome search returns songs | Songs not already in Q playlist added via `updatePlaylist` | Skip duplicate IDs silently |
| Artist not in library | Last.fm top artist, Navidrome search empty | POST artist to Lidarr `/api/v1/artist` (monitored=true) | Log 4xx/5xx; skip artist; continue loop |
| No starred songs in Q playlist | Quarterly archive job | Songs older than 4 weeks removed + files deleted; songs within 4-week grace period carried over to next quarter | Log warning: "0 starred songs archived for YYYY-Q{n}" |
| Song added 2 weeks before quarter end | Quarterly archive, song not starred | Song NOT deleted — carried over to next quarter playlist (within 4-week grace) | N/A |
| Artist already monitored in Lidarr | POST returns 400 duplicate | Swallow error; do not re-add | Log "already monitored" at DEBUG |
| Scheduler missed quarter boundary (pod was down) | Pod restarts after Q-end date | Jobs fire at next scheduled interval; no retroactive run | Acceptable data loss for homelab |
| Annual best-of: no Q playlists found | Jan 1 job, no `YYYY-Q*` playlists exist | Skip creation; log warning | Log only; no crash |

</frozen-after-approval>

## Code Map

- `workloads/navidrome/deployment.yaml` -- envFrom pattern (configMapRef + secretRef); Navidrome ClusterIP service name/namespace for ND_URL
- `workloads/navidrome/configmap.yaml` -- ND_LASTFM_ENABLED, ND user config patterns
- `workloads/lidarr/deployment-lidarr.yaml` -- Lidarr ClusterIP `lidarr.lidarr.svc.cluster.local:8686`; qualityProfileId in soularr config
- `workloads/lidarr/deployment-soularr.yaml` -- ConfigMap-mounted config file pattern via volumeMount; exec startupProbe `test -s /data/config.ini`
- `workloads/komga/kustomization.yaml` -- labels block shape (`includeSelectors: false`, part-of, instance)
- `workloads/lidarr/sealedsecret-slskd.yaml` -- kubeseal header comment format to copy

## Tasks & Acceptance

**Execution:**
- [x] `workloads/music-curator/namespace.yaml` -- namespace `music-curator`
- [x] `workloads/music-curator/configmap.yaml` -- two ConfigMap objects in one file: (1) `music-curator-config`: env vars `ND_URL` (Navidrome ClusterIP FQDN + Subsonic path prefix `/rest`), `ND_USER` (navidrome admin user), `LIDARR_URL` (`http://lidarr.lidarr.svc.cluster.local:8686`), `LASTFM_USER` (scrobbling account username), `TZ=Asia/Seoul`; (2) `music-curator-script`: key `curator.py` containing the full Python script with `# /// script` inline deps block (`requests`, `apscheduler==3.*`, `pylast`), three functions (`weekly_discovery`, `quarterly_archive`, `annual_best_of`), and a `BlockingScheduler` wired to cron triggers (weekly Mon 03:00 KST; quarterly 1st of Jan/Apr/Jul/Oct 02:00 KST; annual Jan 1 03:00 KST); on startup calls `get_or_create_playlist(current_quarter())` immediately (so the playlist exists in Symfonium before the first weekly job fires), then writes `/tmp/started` and starts the scheduler. `weekly_discovery` logic: `user.get_recent_tracks(limit=100)` → unique artists → for each `artist.get_similar(limit=5)` → for each similar artist `artist.get_top_tracks(limit=5)` → search each in Navidrome, add to current Q playlist if found, else POST artist to Lidarr. `quarterly_archive`: get current Q playlist → Navidrome `getStarred2` → skip songs within 4-week grace (carry to new quarter playlist) → for remaining unstarred songs: resolve Lidarr trackFileId via artist+album lookup then path match → `DELETE /api/v1/trackFile/{id}` (frees disk) → remove from playlist
- [x] `workloads/music-curator/sealedsecret.yaml` -- `music-curator-secrets` with keys `ND_PASSWORD`, `LIDARR_API_KEY`, `LASTFM_API_KEY`, `LASTFM_API_SECRET`; placeholder encryptedData; kubeseal header (copy sealedsecret-slskd.yaml comment format); sealed to name=`music-curator-secrets` ns=`music-curator`
- [x] `workloads/music-curator/deployment.yaml` -- image `ghcr.io/astral-sh/uv:python3.12-bookworm-slim` digest-pinned; `command: ["uv", "run", "/scripts/curator.py"]`; `volumeMounts`: script ConfigMap → `/scripts/curator.py` (subPath `curator.py`); `envFrom`: configMapRef `music-curator-config` + secretRef `music-curator-secrets`; resources `requests: cpu:50m mem:64Mi limits: cpu:200m mem:128Mi`; strategy Recreate; `startupProbe: exec: ["sh","-c","test -f /tmp/started"] failureThreshold:60 periodSeconds:5`; no readiness/liveness
- [x] `workloads/music-curator/kustomization.yaml` -- list all resources; labels block (includeSelectors:false, part-of: music-curator, instance: music-curator, managed-by: argocd)

**Acceptance Criteria:**
- Given the filled manifests, when `kustomize build workloads/music-curator` runs, then it renders clean with 1 Namespace, 2 ConfigMaps, 1 SealedSecret, 1 Deployment — no errors.
- Given the Deployment spec, when inspected, then no HTTP Service or Ingress exists, image is `@sha256:` pinned, and `uv run /scripts/curator.py` is the entrypoint.
- Given the curator.py script, when the `quarterly_archive` function runs on a playlist with 3 songs (2 starred, 1 not) **all older than 4 weeks**, then the unstarred song's track file is deleted via Lidarr API and only the 2 starred songs remain in the playlist.
- Given the curator.py script, when `weekly_discovery` finds an artist already in the current quarter's playlist, then no duplicate `songIdToAdd` call is made for that song.
- Given any IngressRoute search in `workloads/music-curator/`, when `grep -r IngressRoute`, then no match (no HTTP exposure).
- Given a fresh pod start, when startupProbe passes, then the current quarter playlist (e.g. `2026-Q3`) already exists in Navidrome — visible in Symfonium before the first weekly job fires.

## Spec Change Log

**2026-06-24 (review loopback #1)**
- **Triggering findings:** E2/A11 (quarterly_archive archives wrong quarter), B7/B8/E3 (Subsonic bracket params ignored), B5/E5 (Lidarr lookup returns MusicBrainz IDs not internal IDs)
- **Amended:** Design Notes — added repeated-params rule, prev-quarter rule; Boundaries — fixed Lidarr trackFile lookup to use `/api/v1/artist` managed endpoint; AC — added "older than 4 weeks" precondition
- **Known-bad state avoided:** archive job silently operating on empty new-quarter playlist; updatePlaylist calls that add/remove nothing; _delete_track_file silently failing for all unmonitored artists
- **KEEP:** 5-file structure, uv+ConfigMap approach, APScheduler Deployment, Subsonic helpers pattern, sealedsecret header format

## Design Notes

- **No PVC / stateless:** Duplicate detection queries the live Navidrome playlist via `getPlaylist` each run. For a weekly job touching ~50–100 songs, this is a single cheap API call — no need to persist seen-set to disk.
- **Grace period tracking:** Navidrome Subsonic `getPlaylist` returns each entry's `created` field (ISO timestamp of when it was added to the playlist). `quarterly_archive` compares `entry.created` against `now - 28 days`; entries newer than that threshold are moved to the new quarter playlist unconditionally.
- **uv cold start:** Pod restart triggers dep reinstall (~15s for 3 packages). startupProbe 5-min buffer absorbs this. No PVC for uv cache — tradeoff accepted for homelab simplicity.
- **uv inline deps:** The `# /// script` PEP 723 header in `curator.py` lets `uv run` install deps into an ephemeral venv on first run (~5s); subsequent runs hit the uv cache baked into the image layer. No Dockerfile needed.
- **Subsonic repeated params:** `updatePlaylist` expects repeated plain keys (`songIdToAdd=x&songIdToAdd=y`, `songIndexToRemove=3&songIndexToRemove=7`), NOT bracket notation (`songIdToAdd[0]=x`). Pass as a list of `(key, value)` tuples to `requests.get(..., params=...)`. Indices for `songIndexToRemove` must be sorted descending to avoid drift.
- **quarterly_archive targets previous quarter:** The job fires on the FIRST DAY of the new quarter (Jan/Apr/Jul/Oct 1). At that moment `current_quarter()` already returns the new quarter. The archive function must call `_prev_quarter(current_quarter())` to get the just-ended quarter's playlist.
- **Lidarr qualityProfileId:** Hard-code `1` (default "Any" profile) in the artist POST. If Lidarr has a custom profile, operator updates the ConfigMap value `LIDARR_QUALITY_PROFILE_ID`.

## Verification

**Commands:**
- `kustomize build workloads/music-curator` -- expected: clean render, 1 Namespace + 2 ConfigMaps + 1 SealedSecret + 1 Deployment
- `grep -r 'IngressRoute\|Service' workloads/music-curator/` -- expected: no matches
- `grep 'image:' workloads/music-curator/deployment.yaml` -- expected: `@sha256:` present

## Suggested Review Order

**Scheduler wiring (entry point)**

- APScheduler jobs + startup playlist creation — read this first for intent
  [`configmap.yaml:502`](../../workloads/music-curator/configmap.yaml#L502)

**Core jobs**

- `weekly_discovery`: Last.fm → similar artists → Navidrome search → Lidarr
  [`configmap.yaml:128`](../../workloads/music-curator/configmap.yaml#L128)

- `quarterly_archive`: prev-quarter logic, grace period, starred check, file delete
  [`configmap.yaml:267`](../../workloads/music-curator/configmap.yaml#L267)

- `annual_best_of`: collect YYYY-Q* playlists → Best-Of
  [`configmap.yaml:445`](../../workloads/music-curator/configmap.yaml#L445)

**Critical helpers (highest-risk logic)**

- `_delete_track_file`: managed-artist lookup → trackFile path match → DELETE
  [`configmap.yaml:366`](../../workloads/music-curator/configmap.yaml#L366)

- `_playlist_add`: repeated-key tuple params (not bracket notation)
  [`configmap.yaml:255`](../../workloads/music-curator/configmap.yaml#L255)

- `_prev_quarter` / `_next_quarter`: boundary arithmetic, Q4→Q1 wrap
  [`configmap.yaml:356`](../../workloads/music-curator/configmap.yaml#L356)

**Deployment & secrets**

- uv image, ConfigMap subPath mount, startupProbe, Recreate strategy
  [`deployment.yaml:1`](../../workloads/music-curator/deployment.yaml#L1)

- Placeholder SealedSecret + kubeseal rotation command
  [`sealedsecret.yaml:1`](../../workloads/music-curator/sealedsecret.yaml#L1)

- ConfigMap env vars (ND_URL, GRACE_PERIOD_DAYS, LIDARR_QUALITY_PROFILE_ID)
  [`configmap.yaml:1`](../../workloads/music-curator/configmap.yaml#L1)
