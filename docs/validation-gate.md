# Validation Gate (external review)

The **Epic 4 entry gate**. The stateful cutovers — ending with the two CRITICAL
stores (n8n, vaultwarden) under write-freeze + parallel-run — start **only after
BOTH** Gate 0 (bare-metal restore drill, `docs/runbooks/bare-metal-recovery.md`)
**and** this Validation Gate show **passed**.

**Gate result: ⛔ NOT YET PASSED** — awaiting collected + triaged feedback.

## What "passed" means (both halves, no exceptions)

1. Feedback is **collected AND triaged** into keep / fix / drop — not merely solicited.
2. **Zero open `data-loss = Y` findings.** Every data-loss finding is forced to
   `fix` and resolved (commit/PR linked) before this gate passes.

Soliciting alone — or triaging while a data-loss finding is still open — does **not** pass.

## The package given to reviewers

At least **two working DevOps/platform engineers**, each asked these three
questions **verbatim**:

1. Where in my backup/restore would I lose data?
2. Would this repo make you want to interview me — if not, what's missing?
3. Where did I over-engineer?

**5-minute path** (point reviewers here):
`README.md` → before/after diagram (`docs/diagrams/excalidraw-before-after.svg`)
→ demo clip (push→deploy) → ADR set (`docs/adr/`, start at `ADR-0001-why-compose-to-k3s`)
→ bare-metal recovery runbook (`docs/runbooks/bare-metal-recovery.md`).

> The self-heal demo clip is deferred to the final epic (post-DONE); the README
> carries clip 1 (push→deploy) and a recording-pending note for the self-heal
> clip. Data-loss paths are reviewable from the runbooks + ADRs + manifests, not
> a video.

## Reviewers (role-based names only — anonymize per AR35)

| Ref | Role | Date received |
|-----|------|---------------|
| Reviewer A | _(DevOps/platform engineer)_ | _pending_ |
| Reviewer B | _(DevOps/platform engineer)_ | _pending_ |

## Raw responses (paste verbatim before triaging)

### Reviewer A
_pending_

### Reviewer B
_pending_

## Triage

| Reviewer | Q (1/2/3) | Finding | Category | Rationale | data-loss? (Y/N) | Remediation (commit/PR) |
|----------|-----------|---------|----------|-----------|------------------|-------------------------|
| _ | _ | _ | _ | _ | _ | _ |

- `keep` — validated as already correct (no code change; record why).
- `fix` — will change. **Every `data-loss = Y` is forced here.**
- `drop` — won't act (record the reason).

## Gate decision

- Reviewer count: **0** / ≥2 required
- Data-loss findings: open **0** / resolved **0**
- Result: **⛔ pending** → flip to **✅ passed (YYYY-MM-DD, N reviewers)** once both
  halves above hold. Epic 4 entry (`architecture.md`) reads both this line and
  "Gate 0 passed".

<!-- Exposure: no real hostnames/IPs/domains in this file — use ${SECRET:*} tokens.
     The full-history exposure scan gates the merge. -->
