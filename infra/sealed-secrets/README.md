# Sealed Secrets — workload secret encryption (Story 2.3)

Encrypts workload secrets so the **sealed** form is safe to commit to this
public repo; the controller decrypts them in-cluster into plain `Secret`s.
The Sealed Secrets Application is a vendor Helm `source` and therefore lives at
[`argocd/apps/sealed-secrets.yaml`](../../argocd/apps/sealed-secrets.yaml)
(wave 0), not here — there are no local manifests to put in `infra/`. This dir
holds the **OOB sealing-key export/restore runbook** (below) and the round-trip
proof — the load-bearing parts of this story.

Decision context: [`docs/DECISIONS.md`](../../docs/DECISIONS.md) and
[ADR-0004](../../docs/adr/ADR-0004-secrets-sealing-key.md).

## What is pinned / configured

- **Controller v0.37.0, chart 2.18.6** (Bitnami `sealed-secrets`), wave 0,
  namespace `sealed-secrets`, release/controller name `sealed-secrets`,
  `ServerSideApply=true` (large CRD). Pin lives in
  [`versions.yaml`](../../versions.yaml); the local `kubeseal` CLI is kept at
  the **same** v0.37.0.
- **Consumption contract: `envFrom: secretRef` ONLY.** No inline `env: ${VAR}`,
  no per-key `env: valueFrom` — both re-introduce the Compose empty-overwrite
  trap (AR22).
- **No `namePrefix` / `commonLabels`.** A SealedSecret is sealed against an exact
  `namespace/name`; Kustomize `namePrefix` rewrites the name and silently breaks
  decryption (AR27). Use the `labels:` field with the mandatory
  `app.kubernetes.io/{name,instance,part-of,managed-by}` set.

## ⚠ The sealing key IS the disaster surface

The controller's private key lives in **etcd**, as one or more `Secret`s in the
`sealed-secrets` namespace labeled `sealedsecrets.bitnami.com/sealed-secrets-key`
(the current one is `=active`). It is **NOT** captured by Longhorn PV backups
(Longhorn backs up volumes; this key is an etcd object). A cluster rebuild or
etcd loss destroys it, and **every SealedSecret ever sealed against it becomes
permanently undecryptable**. The OOB export below is therefore load-bearing, not
optional — **Gate 0 (Story 2.6) restores from it**; without it, Gate 0 fails.

## Operator runbook — export the sealing key out-of-band (AC2 / AR12)

> **Operator-run, against the live cluster.** Produces real key material. The
> only artifact that leaves the cluster is an **age-encrypted** `.age` file
> stored **off-host** (Plane 0). NEVER commit the plaintext key, and NEVER commit
> even the `.age` file — `internal/` is git-ignored and the exposure gate fails
> any commit carrying a raw key.

### 1. Export ALL sealing-key Secrets (not just the active one)

The controller rotates keys: it periodically adds a **new** active key and keeps
the old ones for decryption. A snapshot of only `=active` goes stale for
already-sealed secrets after a renewal — so export **all** of them in one file.

```sh
kubectl -n sealed-secrets get secret \
  -l sealedsecrets.bitnami.com/sealed-secrets-key \
  -o yaml > /tmp/ss-keys.yaml          # plaintext — /tmp only, shred after step 2
```

### 2. Age-encrypt and store off-host (Plane 0)

```sh
# Passphrase-based (simplest); or `age -r <recipient-pubkey>` for key-based.
age -p -o sealed-secrets-keys.$(date +%Y%m%d).yaml.age /tmp/ss-keys.yaml
shred -u /tmp/ss-keys.yaml             # destroy the plaintext immediately

# Move the .age ciphertext OFF this host to Plane 0 (e.g. password manager /
# offline media). It must NOT live only on a cluster node, and must NOT be
# committed (not even to internal/ in a pushed repo).
```

### 3. Restore path (exercised in Gate 0 / Story 2.6)

On a clean cluster, the restored key must be applied **before/at** controller
start so the controller adopts it instead of generating a fresh one (a fresh key
cannot decrypt existing SealedSecrets):

```sh
age -d sealed-secrets-keys.YYYYMMDD.yaml.age > /tmp/ss-keys.yaml
kubectl create namespace sealed-secrets --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f /tmp/ss-keys.yaml     # restore key(s) into the controller namespace
shred -u /tmp/ss-keys.yaml
# THEN let ArgoCD install the controller (wave 0) — it finds the existing key and adopts it.
# Verify: a previously-sealed SealedSecret materializes its Secret again.
```

### Rotation caveat — re-export after renewal

Default controller key renewal keeps old keys but adds a new `active` one. **Pick
one and stick to it:** (a) re-run the export after every renewal, (b) always
export ALL `sealed-secrets-key` Secrets (step 1 already does this — so a fresh
export after each renewal is the simplest discipline), or (c) disable rotation if
a single stable key is preferred. We export ALL keys each time and re-export on
renewal.

## Operator runbook — prove the round-trip (AC1 / FR24, FR25)

> Throwaway smoke test: a one-key SealedSecret consumed by a test pod via
> `envFrom: secretRef`, torn down after. Proves controller → `Secret` →
> workload. Commit only the **sealed** form if you keep any of it; never the
> plaintext `Secret`.

```sh
# 0. fetch THIS cluster's public cert (sealing is offline; decryption is controller-side)
kubeseal --fetch-cert \
  --controller-namespace sealed-secrets --controller-name sealed-secrets > /tmp/pub-cert.pem

# 1. create a plaintext Secret locally, seal it (NEVER apply the plaintext)
kubectl create secret generic demo-secrets \
  --from-literal=DEMO_KEY=it-works --namespace default \
  --dry-run=client -o yaml \
  | kubeseal --cert /tmp/pub-cert.pem --format yaml > /tmp/demo-sealedsecret.yaml

# 2. apply the SEALED form; the controller materializes a Secret of the same name+ns
kubectl apply -f /tmp/demo-sealedsecret.yaml
kubectl -n default get sealedsecret demo-secrets
kubectl -n default get secret demo-secrets          # appears once reconciled

# 3. consume via envFrom: secretRef ONLY (the contract under test)
kubectl -n default run ss-probe --image=busybox:1.36 --restart=Never \
  --overrides='{"spec":{"containers":[{"name":"p","image":"busybox:1.36","command":["sh","-c","echo $DEMO_KEY; sleep 5"],"envFrom":[{"secretRef":{"name":"demo-secrets"}}]}]}}'
kubectl -n default logs ss-probe        # MUST print: it-works

# 4. tear down (throwaway)
kubectl -n default delete pod ss-probe sealedsecret/demo-secrets secret/demo-secrets
```

Note on "re-seal Epic 1 SealedSecrets": there are **none** — the Epic 1
Excalidraw manifests are stateless and carry no SealedSecret, so nothing from
Phase 1 needs re-sealing here.
