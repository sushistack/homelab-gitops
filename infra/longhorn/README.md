# Longhorn — removed

Longhorn was removed in favour of k3s's built-in `local-path` provisioner (`rancher.io/local-path`).
See [`infra/local-path/`](../local-path/) for the replacement StorageClass (`local-path-retain`).

## Operator cleanup required (post-merge, on live cluster)

```sh
# 1. Verify all workload PVCs migrated off Longhorn
kubectl get pvc -A | grep longhorn   # expect: no results

# 2. Remove Longhorn namespace + CRDs (ArgoCD does NOT cascade-delete after app removal)
kubectl delete namespace longhorn-system
kubectl get crd | grep longhorn.io | awk '{print $1}' | xargs kubectl delete crd

# 3. Confirm local-path-retain StorageClass is present and Healthy in ArgoCD
kubectl get sc local-path-retain

# 4. Delete the leftover Longhorn StorageClasses (not GitOps-managed, survive step 2)
kubectl get pv -o jsonpath='{.items[*].spec.storageClassName}' | tr ' ' '\n' | grep longhorn  # expect: nothing
kubectl delete sc longhorn longhorn-static
kubectl delete csidriver driver.longhorn.io
kubectl delete clusterrolebinding longhorn-bind longhorn-support-bundle
kubectl delete clusterrole longhorn-role
kubectl delete priorityclass longhorn-critical

# 5. Old replica data on each node VM (~8.3G each)
rm -rf /var/lib/longhorn
```

Steps 1–4 done on the live cluster as of 2026-11-28. Step 5 still pending.
