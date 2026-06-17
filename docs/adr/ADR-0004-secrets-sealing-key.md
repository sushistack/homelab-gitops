# ADR-0004: Sealed Secrets — the sealing key is a cluster-bound Plane 0 asset, exported out-of-band

Affected services: sealed-secrets (and every later workload that consumes a SealedSecret-materialized `Secret`)

> Decision record. Back-reference: [README → Decision records](../../README.md#decision-records-adrs).

## Context

Workload secrets must never appear in plaintext in this **public** Git repo, yet
they must reconcile through GitOps like everything else. Sealed Secrets (Bitnami)
solves this: a public cert seals secrets offline into a `SealedSecret` CR that is
safe to commit; the in-cluster controller decrypts it with a private key into a
plain `Secret`. That private key — the "sealing key" — is the entire trust
anchor. It lives in **etcd** as one or more `Secret`s in the `sealed-secrets`
namespace (labeled `sealedsecrets.bitnami.com/sealed-secrets-key`), **not** on a
Longhorn PV. So [ADR-0003](ADR-0003-longhorn-single-host-storage.md)'s storage
backups do **not** capture it: a cluster rebuild or etcd loss destroys the key and
every SealedSecret sealed against it becomes permanently undecryptable.

Phase 1 deliberately had no Sealed Secrets (the Excalidraw pilot was stateless,
held no secret). Phase 2a is a clean rebuild, so there is nothing to migrate — but
that also means the boundary must be stated so no one expects a Phase 1 sealed
asset to decrypt here.

## Decision

Adopt **Sealed Secrets controller v0.37.0 (chart 2.18.6), wave 0**, and treat the
sealing key as a **Plane 0 asset exported out-of-band**:

- The controller installs at sync-wave 0 (alongside Longhorn, before
  cert-manager) so the CRD + controller exist before any later-wave workload
  references a materialized `Secret`.
- The sealing key is **exported OOB, age-encrypted, and stored off-host** — the
  only artifact that leaves the cluster is a `.age` ciphertext, never committed
  (not even to `internal/`). This export is what **Gate 0 (Story 2.6)** restores
  during bare-metal recovery; without it, recovery is impossible. Export **all**
  `sealed-secrets-key` Secrets and re-export after any key renewal (runbook:
  [`infra/sealed-secrets/README.md`](../../infra/sealed-secrets/README.md)).
- **Consumption is `envFrom: secretRef` only** — no inline `env: ${VAR}`, no
  per-key `valueFrom` (both re-introduce the Compose empty-overwrite trap).
- **The sealing key is cluster-bound:** every SealedSecret here is sealed against
  THIS cluster's public cert, so Phase 1 sealed assets are undecryptable on this
  Phase 2a cluster — documented boundary, not a bug. Phase 1 held no real
  secrets, so nothing carries over.

## Consequences

- A clean rebuild without restoring the exported key generates a **fresh** key
  that cannot decrypt any existing SealedSecret. The OOB export + the Gate 0
  restore step are therefore load-bearing, not nice-to-haves.
- The key rotates (controller adds a new active key, keeps old ones for
  decryption), so a one-time export goes stale for newly-sealed secrets — the
  runbook mandates exporting all keys and re-exporting on renewal.
- **No `namePrefix` / `commonLabels`** on any SealedSecret: the seal binds to an
  exact `namespace/name`, which Kustomize name rewriting silently breaks.

## Rejected alternatives

- **Put bootstrap creds (ArgoCD repo access, Cloudflare DNS-01 token) through
  Sealed Secrets too.** That creates a bootstrap circular dependency — the
  controller needs the cluster up, but those creds are needed to bring it up.
  Bootstrap creds stay **Ansible-injected plain Secrets**; only **workload**
  secrets flow through Sealed Secrets. Rejected.
- **Rely on Longhorn/PV backups to protect the key.** The key is an etcd object,
  not a PV — storage backups never see it. Assuming otherwise is the exact silent
  data-loss trap this ADR exists to prevent. Rejected.
- **SOPS / external secret managers (Vault, cloud KMS).** Heavier operational
  surface for a single-operator homelab; Sealed Secrets keeps the secret in Git
  (auditable, GitOps-native) with one small key to protect OOB. Rejected for now.

## Exposure note

Safe to show publicly: the architecture (sealed form in Git, key in etcd, OOB
age-encrypted export), the version pins, and the namespace/label names. No real
secret value, key material, hostname, or IP appears here. The exported key and its
`.age` ciphertext are off-repo Plane 0 assets and never tracked — the exposure
gate fails any commit carrying a raw key.
