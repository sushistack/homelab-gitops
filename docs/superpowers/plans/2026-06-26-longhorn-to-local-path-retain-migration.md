# Longhorn → local-path-retain PVC Migration Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Migrate 4 PVCs across 3 namespaces (anytype, ntfy, vaultwarden) from the `longhorn` StorageClass to `local-path-retain`, preserving all data, with zero data loss.

**Architecture:** For each PVC: scale workloads to zero, rsync data via a migration pod pinned to the storage node (k3s-cp-1), rebind the new local-path-retain PV to the original PVC name, then restore workloads. anytype's two PVCs share a single scale-down/scale-up cycle.

**Tech Stack:** kubectl, k3s, Longhorn (source), local-path-retain (target), alpine/rsync migration pod

## Global Constraints

- Storage node: `k3s-cp-1`, node label `storage-node=true`
- Target StorageClass: `local-path-retain`
- Migration pod image: `alpine:latest` (installs rsync via apk)
- Migration pod nodeSelector: `{storage-node: "true"}`
- Max wait for migration pod: 15 minutes (anytype-data ~550MB)
- PVC annotation on new PVCs: `argocd.argoproj.io/sync-options: Prune=false`
- Never scale back up until ALL PVCs in a namespace are migrated

---

### Task 1: Migrate anytype-data (5Gi)

**Context:** anytype namespace has two deploys (anytype, anytype-heart) and two PVCs. Scale both deploys down before touching either PVC. Only scale back up after Task 2 completes.

**Files:** No git files changed — this is live cluster operations only.

- [ ] **Step 1: Scale down both anytype deploys**

```bash
kubectl scale deploy anytype anytype-heart -n anytype --replicas=0
kubectl rollout status deploy/anytype -n anytype --timeout=60s
kubectl rollout status deploy/anytype-heart -n anytype --timeout=60s
```

Expected: Both deployments scaled to 0.

- [ ] **Step 2: Verify no pods running in anytype namespace**

```bash
kubectl get pods -n anytype
```

Expected: No resources found / all pods Terminating or gone.

- [ ] **Step 3: Create temp PVC anytype-data-mig**

```bash
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: anytype-data-mig
  namespace: anytype
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: local-path-retain
  resources:
    requests:
      storage: 5Gi
EOF
```

- [ ] **Step 4: Wait for temp PVC to bind**

```bash
kubectl wait pvc/anytype-data-mig -n anytype --for=jsonpath='{.status.phase}'=Bound --timeout=60s
kubectl get pvc anytype-data-mig -n anytype
```

Expected: STATUS=Bound.

- [ ] **Step 5: Create migration pod for anytype-data**

```bash
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: migrate-anytype-data
  namespace: anytype
spec:
  nodeSelector:
    storage-node: "true"
  restartPolicy: Never
  containers:
  - name: migrate
    image: alpine:latest
    command: ["/bin/sh", "-c", "apk add --no-cache rsync && rsync -av /old/ /new/ && echo DONE"]
    volumeMounts:
    - name: old
      mountPath: /old
    - name: new
      mountPath: /new
  volumes:
  - name: old
    persistentVolumeClaim:
      claimName: anytype-data
  - name: new
    persistentVolumeClaim:
      claimName: anytype-data-mig
EOF
```

- [ ] **Step 6: Wait for migration pod to succeed (up to 15 min)**

```bash
kubectl wait pod/migrate-anytype-data -n anytype --for=condition=Ready --timeout=30s || true
kubectl wait pod/migrate-anytype-data -n anytype --for=jsonpath='{.status.phase}'=Succeeded --timeout=900s
```

- [ ] **Step 7: Verify DONE in pod logs**

```bash
kubectl logs migrate-anytype-data -n anytype | tail -5
```

Expected: Last line is `DONE`.

- [ ] **Step 8: Get PV name from temp PVC**

```bash
PV=$(kubectl get pvc anytype-data-mig -n anytype -o jsonpath='{.spec.volumeName}')
echo "PV: $PV"
```

- [ ] **Step 9: Patch temp PVC finalizers to [] then delete**

```bash
PV=$(kubectl get pvc anytype-data-mig -n anytype -o jsonpath='{.spec.volumeName}')
kubectl patch pvc anytype-data-mig -n anytype -p '{"metadata":{"finalizers":[]}}' --type=merge
kubectl delete pvc anytype-data-mig -n anytype
```

- [ ] **Step 10: Patch PV claimRef away (repeat until Available)**

```bash
PV=$(kubectl get pvc anytype-data-mig -n anytype -o jsonpath='{.spec.volumeName}' 2>/dev/null || echo "ALREADY_DELETED")
# If PVC already gone, you need the PV name from Step 8 — store it:
# PV=<value from Step 8>
kubectl patch pv $PV --type=json -p='[{"op":"remove","path":"/spec/claimRef"}]'
sleep 2
kubectl get pv $PV -o jsonpath='{.status.phase}'
```

Repeat the patch+sleep+get until phase shows `Available`. Usually 1-3 attempts.

- [ ] **Step 11: Delete old anytype-data Longhorn PVC**

```bash
kubectl patch pvc anytype-data -n anytype -p '{"metadata":{"finalizers":[]}}' --type=merge
kubectl delete pvc anytype-data -n anytype
# If stuck Terminating, repeat the finalizer patch:
# kubectl patch pvc anytype-data -n anytype -p '{"metadata":{"finalizers":[]}}' --type=merge
```

- [ ] **Step 12: Verify PV is Available and claimRef is empty**

```bash
# PV=<value from Step 8>
kubectl get pv $PV -o jsonpath='{.status.phase}'
kubectl get pv $PV -o jsonpath='{.spec.claimRef}'
```

Expected: phase=`Available`, claimRef=`` (empty).

- [ ] **Step 13: Create new anytype-data PVC bound to the local-path-retain PV**

```bash
# PV=<value from Step 8>
kubectl apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: anytype-data
  namespace: anytype
  annotations:
    argocd.argoproj.io/sync-options: Prune=false
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: local-path-retain
  volumeName: $PV
  resources:
    requests:
      storage: 5Gi
EOF
```

- [ ] **Step 14: Wait for new PVC to bind**

```bash
kubectl wait pvc/anytype-data -n anytype --for=jsonpath='{.status.phase}'=Bound --timeout=60s
kubectl get pvc anytype-data -n anytype
```

Expected: STATUS=Bound, STORAGECLASS=local-path-retain.

If Pending: check `kubectl get pv $PV -o jsonpath='{.spec.claimRef}'` — if stale, patch claimRef away again and re-wait.

---

### Task 2: Migrate anytype-heart-data (2Gi)

**Context:** Deploys remain at 0 from Task 1. Proceed immediately after Task 1 Step 14 confirms bind.

- [ ] **Step 1: Create temp PVC anytype-heart-data-mig**

```bash
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: anytype-heart-data-mig
  namespace: anytype
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: local-path-retain
  resources:
    requests:
      storage: 2Gi
EOF
kubectl wait pvc/anytype-heart-data-mig -n anytype --for=jsonpath='{.status.phase}'=Bound --timeout=60s
```

- [ ] **Step 2: Create migration pod for anytype-heart-data**

```bash
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: migrate-anytype-heart-data
  namespace: anytype
spec:
  nodeSelector:
    storage-node: "true"
  restartPolicy: Never
  containers:
  - name: migrate
    image: alpine:latest
    command: ["/bin/sh", "-c", "apk add --no-cache rsync && rsync -av /old/ /new/ && echo DONE"]
    volumeMounts:
    - name: old
      mountPath: /old
    - name: new
      mountPath: /new
  volumes:
  - name: old
    persistentVolumeClaim:
      claimName: anytype-heart-data
  - name: new
    persistentVolumeClaim:
      claimName: anytype-heart-data-mig
EOF
```

- [ ] **Step 3: Wait for migration pod to succeed (up to 15 min)**

```bash
kubectl wait pod/migrate-anytype-heart-data -n anytype --for=jsonpath='{.status.phase}'=Succeeded --timeout=900s
kubectl logs migrate-anytype-heart-data -n anytype | tail -5
```

Expected: Last line is `DONE`.

- [ ] **Step 4: Get PV name, detach temp PVC, rebind to original name**

```bash
PV2=$(kubectl get pvc anytype-heart-data-mig -n anytype -o jsonpath='{.spec.volumeName}')
echo "PV2: $PV2"
kubectl patch pvc anytype-heart-data-mig -n anytype -p '{"metadata":{"finalizers":[]}}' --type=merge
kubectl delete pvc anytype-heart-data-mig -n anytype
# Patch claimRef away, repeat until Available:
kubectl patch pv $PV2 --type=json -p='[{"op":"remove","path":"/spec/claimRef"}]'
sleep 2
kubectl get pv $PV2 -o jsonpath='{.status.phase}'
```

- [ ] **Step 5: Delete old anytype-heart-data Longhorn PVC**

```bash
kubectl patch pvc anytype-heart-data -n anytype -p '{"metadata":{"finalizers":[]}}' --type=merge
kubectl delete pvc anytype-heart-data -n anytype
```

- [ ] **Step 6: Verify PV2 Available and claimRef empty**

```bash
kubectl get pv $PV2 -o jsonpath='{.status.phase}'
kubectl get pv $PV2 -o jsonpath='{.spec.claimRef}'
```

- [ ] **Step 7: Create new anytype-heart-data PVC**

```bash
# PV2=<value from Step 4>
kubectl apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: anytype-heart-data
  namespace: anytype
  annotations:
    argocd.argoproj.io/sync-options: Prune=false
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: local-path-retain
  volumeName: $PV2
  resources:
    requests:
      storage: 2Gi
EOF
kubectl wait pvc/anytype-heart-data -n anytype --for=jsonpath='{.status.phase}'=Bound --timeout=60s
kubectl get pvc -n anytype
```

Expected: Both anytype-data and anytype-heart-data Bound with STORAGECLASS=local-path-retain.

- [ ] **Step 8: Scale anytype deploys back up**

```bash
kubectl scale deploy anytype anytype-heart -n anytype --replicas=1
kubectl rollout status deploy/anytype -n anytype --timeout=120s
kubectl rollout status deploy/anytype-heart -n anytype --timeout=120s
```

- [ ] **Step 9: Restart deploys and verify pods Running**

```bash
kubectl rollout restart deploy/anytype deploy/anytype-heart -n anytype
kubectl rollout status deploy/anytype -n anytype --timeout=120s
kubectl rollout status deploy/anytype-heart -n anytype --timeout=120s
kubectl get pods -n anytype
```

Expected: All pods Running and Ready.

- [ ] **Step 10: Delete migration pods**

```bash
kubectl delete pod migrate-anytype-data migrate-anytype-heart-data -n anytype --ignore-not-found
```

---

### Task 3: Migrate ntfy-data (1Gi)

- [ ] **Step 1: Scale down ntfy deploy**

```bash
kubectl scale deploy ntfy -n ntfy --replicas=0
kubectl rollout status deploy/ntfy -n ntfy --timeout=60s
```

- [ ] **Step 2: Create temp PVC ntfy-data-mig**

```bash
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ntfy-data-mig
  namespace: ntfy
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: local-path-retain
  resources:
    requests:
      storage: 1Gi
EOF
kubectl wait pvc/ntfy-data-mig -n ntfy --for=jsonpath='{.status.phase}'=Bound --timeout=60s
```

- [ ] **Step 3: Create migration pod for ntfy-data**

```bash
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: migrate-ntfy-data
  namespace: ntfy
spec:
  nodeSelector:
    storage-node: "true"
  restartPolicy: Never
  containers:
  - name: migrate
    image: alpine:latest
    command: ["/bin/sh", "-c", "apk add --no-cache rsync && rsync -av /old/ /new/ && echo DONE"]
    volumeMounts:
    - name: old
      mountPath: /old
    - name: new
      mountPath: /new
  volumes:
  - name: old
    persistentVolumeClaim:
      claimName: ntfy-data
  - name: new
    persistentVolumeClaim:
      claimName: ntfy-data-mig
EOF
```

- [ ] **Step 4: Wait for migration pod to succeed**

```bash
kubectl wait pod/migrate-ntfy-data -n ntfy --for=jsonpath='{.status.phase}'=Succeeded --timeout=300s
kubectl logs migrate-ntfy-data -n ntfy | tail -5
```

Expected: Last line is `DONE`.

- [ ] **Step 5: Get PV, detach, rebind**

```bash
PV3=$(kubectl get pvc ntfy-data-mig -n ntfy -o jsonpath='{.spec.volumeName}')
echo "PV3: $PV3"
kubectl patch pvc ntfy-data-mig -n ntfy -p '{"metadata":{"finalizers":[]}}' --type=merge
kubectl delete pvc ntfy-data-mig -n ntfy
kubectl patch pv $PV3 --type=json -p='[{"op":"remove","path":"/spec/claimRef"}]'
sleep 2
kubectl get pv $PV3 -o jsonpath='{.status.phase}'
# Repeat patch until Available
```

- [ ] **Step 6: Delete old ntfy-data Longhorn PVC**

```bash
kubectl patch pvc ntfy-data -n ntfy -p '{"metadata":{"finalizers":[]}}' --type=merge
kubectl delete pvc ntfy-data -n ntfy
```

- [ ] **Step 7: Verify PV3 Available**

```bash
kubectl get pv $PV3 -o jsonpath='{.status.phase}'
kubectl get pv $PV3 -o jsonpath='{.spec.claimRef}'
```

- [ ] **Step 8: Create new ntfy-data PVC**

```bash
# PV3=<value from Step 5>
kubectl apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ntfy-data
  namespace: ntfy
  annotations:
    argocd.argoproj.io/sync-options: Prune=false
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: local-path-retain
  volumeName: $PV3
  resources:
    requests:
      storage: 1Gi
EOF
kubectl wait pvc/ntfy-data -n ntfy --for=jsonpath='{.status.phase}'=Bound --timeout=60s
kubectl get pvc -n ntfy
```

- [ ] **Step 9: Scale up, restart, verify**

```bash
kubectl scale deploy ntfy -n ntfy --replicas=1
kubectl rollout restart deploy/ntfy -n ntfy
kubectl rollout status deploy/ntfy -n ntfy --timeout=120s
kubectl get pods -n ntfy
kubectl delete pod migrate-ntfy-data -n ntfy --ignore-not-found
```

Expected: ntfy pod Running and Ready.

---

### Task 4: Migrate vaultwarden-data (2Gi) — HIGHEST STAKES

**Context:** Extra care. Verify pod Ready explicitly at the end.

- [ ] **Step 1: Scale down vaultwarden**

```bash
kubectl scale deploy vaultwarden -n vaultwarden --replicas=0
kubectl rollout status deploy/vaultwarden -n vaultwarden --timeout=60s
kubectl get pods -n vaultwarden
```

Expected: No pods running.

- [ ] **Step 2: Create temp PVC vaultwarden-data-mig**

```bash
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: vaultwarden-data-mig
  namespace: vaultwarden
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: local-path-retain
  resources:
    requests:
      storage: 2Gi
EOF
kubectl wait pvc/vaultwarden-data-mig -n vaultwarden --for=jsonpath='{.status.phase}'=Bound --timeout=60s
kubectl get pvc -n vaultwarden
```

- [ ] **Step 3: Create migration pod for vaultwarden-data**

```bash
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: migrate-vaultwarden-data
  namespace: vaultwarden
spec:
  nodeSelector:
    storage-node: "true"
  restartPolicy: Never
  containers:
  - name: migrate
    image: alpine:latest
    command: ["/bin/sh", "-c", "apk add --no-cache rsync && rsync -av /old/ /new/ && echo DONE"]
    volumeMounts:
    - name: old
      mountPath: /old
    - name: new
      mountPath: /new
  volumes:
  - name: old
    persistentVolumeClaim:
      claimName: vaultwarden-data
  - name: new
    persistentVolumeClaim:
      claimName: vaultwarden-data-mig
EOF
```

- [ ] **Step 4: Wait for migration pod to succeed**

```bash
kubectl wait pod/migrate-vaultwarden-data -n vaultwarden --for=jsonpath='{.status.phase}'=Succeeded --timeout=300s
kubectl logs migrate-vaultwarden-data -n vaultwarden | tail -5
```

Expected: Last line is `DONE`. If not, STOP — do not proceed.

- [ ] **Step 5: Get PV, detach temp PVC**

```bash
PV4=$(kubectl get pvc vaultwarden-data-mig -n vaultwarden -o jsonpath='{.spec.volumeName}')
echo "PV4: $PV4"
kubectl patch pvc vaultwarden-data-mig -n vaultwarden -p '{"metadata":{"finalizers":[]}}' --type=merge
kubectl delete pvc vaultwarden-data-mig -n vaultwarden
```

- [ ] **Step 6: Patch PV claimRef away (repeat until Available)**

```bash
# PV4=<from Step 5>
kubectl patch pv $PV4 --type=json -p='[{"op":"remove","path":"/spec/claimRef"}]'
sleep 2
kubectl get pv $PV4 -o jsonpath='{.status.phase}'
# Repeat until: Available
```

- [ ] **Step 7: Delete old vaultwarden-data Longhorn PVC**

```bash
kubectl patch pvc vaultwarden-data -n vaultwarden -p '{"metadata":{"finalizers":[]}}' --type=merge
kubectl delete pvc vaultwarden-data -n vaultwarden
# If stuck Terminating, re-run the finalizer patch
```

- [ ] **Step 8: Verify PV4 Available and claimRef empty**

```bash
kubectl get pv $PV4 -o jsonpath='{.status.phase}'
kubectl get pv $PV4 -o jsonpath='{.spec.claimRef}'
```

Expected: `Available` and empty claimRef. If claimRef not empty, patch it away again.

- [ ] **Step 9: Create new vaultwarden-data PVC**

```bash
# PV4=<from Step 5>
kubectl apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: vaultwarden-data
  namespace: vaultwarden
  annotations:
    argocd.argoproj.io/sync-options: Prune=false
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: local-path-retain
  volumeName: $PV4
  resources:
    requests:
      storage: 2Gi
EOF
kubectl wait pvc/vaultwarden-data -n vaultwarden --for=jsonpath='{.status.phase}'=Bound --timeout=60s
kubectl get pvc -n vaultwarden
```

- [ ] **Step 10: Scale up, restart, verify Running and Ready**

```bash
kubectl scale deploy vaultwarden -n vaultwarden --replicas=1
kubectl rollout restart deploy/vaultwarden -n vaultwarden
kubectl rollout status deploy/vaultwarden -n vaultwarden --timeout=120s
kubectl get pods -n vaultwarden -o wide
```

Expected: vaultwarden pod Running, READY=1/1.

- [ ] **Step 11: Explicit readiness check**

```bash
kubectl wait pod -n vaultwarden -l app.kubernetes.io/name=vaultwarden --for=condition=Ready --timeout=60s 2>/dev/null || \
kubectl wait pod -n vaultwarden -l app=vaultwarden --for=condition=Ready --timeout=60s 2>/dev/null || \
kubectl get pods -n vaultwarden
```

- [ ] **Step 12: Delete migration pod**

```bash
kubectl delete pod migrate-vaultwarden-data -n vaultwarden --ignore-not-found
```

---

### Task 5: Final Verification

- [ ] **Step 1: Show all migrated PVCs**

```bash
kubectl get pvc -n anytype
kubectl get pvc -n ntfy
kubectl get pvc -n vaultwarden
```

Expected: All PVCs Bound with STORAGECLASS=local-path-retain.

- [ ] **Step 2: Show pod status for all services**

```bash
kubectl get pods -n anytype
kubectl get pods -n ntfy
kubectl get pods -n vaultwarden
```

Expected: All pods Running and Ready.

- [ ] **Step 3: Confirm no Longhorn PVCs remain for these namespaces**

```bash
kubectl get pvc -A | grep longhorn | grep -E 'anytype|ntfy|vaultwarden'
```

Expected: No output.
