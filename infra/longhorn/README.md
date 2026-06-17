# Longhorn — storage (Story 2.2)

Persistent storage for the cluster. The Longhorn Application is a vendor Helm
`source` and therefore lives at [`argocd/apps/longhorn.yaml`](../../argocd/apps/longhorn.yaml)
(wave 0), not here — there are no local manifests to put in `infra/`. This dir
holds the SPOF note and the reschedule-proof runbook.

## The single-host SPOF (read this before trusting replication)

All three k3s nodes run on **one Proxmox host with effectively one disk**. So
Longhorn's 3-way replication protects against **VM loss / disk-image corruption /
pod mobility across the VMs** — **NOT host loss**. One host = one failure domain;
a host reboot or PSU/disk failure takes all three replicas down together. This is
a deliberate, documented limitation, not a hidden flaw — full reasoning in
[ADR-0003](../../docs/adr/ADR-0003-longhorn-single-host-storage.md). Durability
against host loss is the bare-metal restore chain (Gate 0, **Story 2.6**) and
self-heal (**Story 2.5**) — replication is not a substitute for either.

## What is pinned / configured

- **Longhorn v1.12.0, V1 data engine** (`defaultSettings.defaultDataEngine: v1`,
  pinned explicitly — V2 went GA in v1.12.0). Pin lives in
  [`versions.yaml`](../../versions.yaml).
- `longhorn` is the **default** StorageClass, `reclaimPolicy: Retain`,
  `numberOfReplicas: 3`. k3s's bundled `local-path` is patched to non-default at
  bootstrap (Ansible) so `longhorn` is the sole default.
- Host prereqs (`open-iscsi`, `nfs-common`, `iscsid` running, `multipathd`
  masked + blacklisted) installed on every node by Play 0 of the Ansible playbook.

## Storage conventions for every later service

`storageClassName: longhorn` (named explicitly, not via default); PVC named
`<service>-data` (multi-volume → `<service>-<purpose>`); `accessModes:
[ReadWriteOnce]`; annotate PVCs `argocd.argoproj.io/sync-options: Prune=false`
so ArgoCD never auto-deletes data.

## Operator runbook — prove a PVC survives cross-node rescheduling (AC2 / FR15)

> **Operator-run, against the live cluster.** This is a standalone smoke test, not
> a real service — it lives in a scratch namespace and is torn down after. A
> same-node restart proves NOTHING; the test MUST force the pod onto a different
> node. Keep any output with real hostnames/IPs out of committed clips (AR26).

### 0. Preconditions

```sh
kubectl -n longhorn-system get pods                 # all Running
kubectl -n longhorn-system get nodes.longhorn.io    # 3 nodes Ready, schedulable disk
kubectl get sc                                      # exactly one (default), and it is longhorn
kubectl get nodes                                   # note node names; pick NODE_A and NODE_B
```

### 1. Create the scratch PVC + a pod pinned to node A, write a canary

```sh
kubectl create namespace longhorn-smoke
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: smoke-data
  namespace: longhorn-smoke
  annotations:
    argocd.argoproj.io/sync-options: Prune=false   # never auto-delete data (models real PVCs)
spec:
  storageClassName: longhorn          # named explicitly per AR15
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 1Gi
EOF

# Pin to NODE_A (replace <NODE_A>), mount the PVC, write a known value.
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: smoke
  namespace: longhorn-smoke
spec:
  nodeName: <NODE_A>
  containers:
    - name: app
      image: busybox:1.36
      command: ["sh", "-c", "sleep 86400"]
      volumeMounts:
        - { name: data, mountPath: /data }
  volumes:
    - name: data
      persistentVolumeClaim: { claimName: smoke-data }
EOF

kubectl -n longhorn-smoke wait --for=condition=Ready pod/smoke --timeout=120s
CANARY="longhorn-smoke-$(date +%s)"
kubectl -n longhorn-smoke exec smoke -- sh -c "echo $CANARY > /data/canary.txt && sync"
echo "wrote: $CANARY"
kubectl -n longhorn-smoke get pod smoke -o wide      # RECORD: which node (must be NODE_A)
```

### 2. Force a genuine cross-node reschedule (A → B)

```sh
kubectl cordon <NODE_A>                               # stop scheduling onto A
kubectl -n longhorn-smoke delete pod smoke            # recreate on a schedulable node (B)
# re-apply the pod WITHOUT nodeName so the scheduler picks B (A is cordoned):
kubectl -n longhorn-smoke run smoke --image=busybox:1.36 \
  --overrides='{"spec":{"containers":[{"name":"app","image":"busybox:1.36","command":["sh","-c","sleep 86400"],"volumeMounts":[{"name":"data","mountPath":"/data"}]}],"volumes":[{"name":"data","persistentVolumeClaim":{"claimName":"smoke-data"}}]}}' \
  --restart=Never
kubectl -n longhorn-smoke wait --for=condition=Ready pod/smoke --timeout=180s
kubectl -n longhorn-smoke get pod smoke -o wide       # RECORD: must be a DIFFERENT node than step 1
```

### 3. Verify re-attach + data intact (the FR15 proof)

```sh
kubectl -n longhorn-system get volumes.longhorn.io    # RECORD: volume now attached to NODE_B
kubectl -n longhorn-smoke exec smoke -- cat /data/canary.txt   # MUST equal the $CANARY from step 1
```

### 4. Prove Retain, then tear down

```sh
kubectl uncordon <NODE_A>
kubectl delete namespace longhorn-smoke               # deletes pod + PVC
kubectl -n longhorn-system get volumes.longhorn.io    # Retain ⇒ the Longhorn volume SURVIVES the PVC delete
# then clean the orphaned volume manually (Longhorn UI or kubectl delete volumes.longhorn.io <name>)
```

**Evidence to capture in the story's Completion Notes:** the canary string, the
`get pod -o wide` before/after showing the A→B move, the `get volumes.longhorn.io`
re-attach to B, the identical canary read back, and the surviving volume after PVC
delete (Retain proof).
