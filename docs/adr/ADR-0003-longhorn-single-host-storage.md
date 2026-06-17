# ADR-0003: Longhorn on a single physical host — replicas guard VM/disk loss, not host loss

Affected services: longhorn (and every later stateful service that binds a `longhorn` PVC)

> Decision record. Back-reference: [README → Decision records](../../README.md#decision-records-adrs).

## Context

Phase 2a needs persistent storage that survives a pod moving between nodes,
before any stateful service relies on it (Story 2.2). The cluster is three k3s
VMs — but all three run on **one Proxmox host with effectively one physical
disk**. Longhorn replicates each volume across the three nodes (one replica per
node, `numberOfReplicas: 3`). On a multi-*host* cluster those replicas would be
real redundancy. Here they are not: the three "nodes" share one box and one
disk, so a host reboot, PSU failure, or disk failure takes all three replicas
down together. It is tempting to present 3-way replication as high availability;
on this topology that would be dishonest. See
[ADR-0001](ADR-0001-why-compose-to-k3s.md) for the top-level Compose → k3s
decision this builds on.

## Decision

Adopt **Longhorn v1.12.0 (V1 data engine, pinned explicitly)** as the cluster's
default `StorageClass` (`reclaimPolicy: Retain`), and **state the single-host
SPOF plainly** rather than imply redundancy it does not have. The honest framing:

- Longhorn replicas here protect against **VM loss, disk-image corruption, and
  pod mobility across the three VMs** — a pod can be rescheduled onto another
  node and its RWO volume re-attaches with data intact (the FR15 proof in
  Story 2.2).
- They do **NOT** protect against **host loss** — one Proxmox host means one
  failure domain; everything dies together. That recovery story is the
  bare-metal restore chain (Gate 0, Story 2.6), not replication.

Longhorn earns its place not as HA but as: RWX / pod-mobility across the VMs,
and satisfying the learning-success criterion (a real k8s storage primitive —
StatefulSet/PVC on Longhorn-backed volumes) the portfolio is built to demonstrate.
The V1 engine is pinned because **V2 went GA in v1.12.0**; leaving the engine
unset risks silently landing on V2.

## Consequences

- Every later stateful service binds `storageClassName: longhorn` explicitly
  (not via the cluster default) and annotates its PVC `Prune=false` so ArgoCD
  never deletes data. `Retain` means a deleted PVC leaves the underlying volume
  for manual cleanup — proven in the Story 2.2 smoke test.
- The single-host limitation is stated **once, authoritatively**, and
  cross-linked bidirectionally with [`infra/longhorn/README.md`](../../infra/longhorn/README.md)
  (operational runbook + the reschedule proof) so the SPOF boundary is never
  re-litigated per service.
- Real durability against host loss depends on the off-host backup/restore chain
  (Gate 0, Story 2.6) and self-heal behaviour (Story 2.5) — replication is not a
  substitute for either, and this ADR says so.
- **Self-heal proven (Story 2.5).** The *software*-HA boundary above is no longer
  theoretical: a node-VM eviction reschedules its pod onto a healthy node and the
  Longhorn RWO volume detaches + re-attaches with the canary intact in **~12 s**
  (well inside the NFR3 ≤5-min ceiling), the volume rebuilds its third replica once
  the node returns, and a deleted PVC leaves the volume behind (`Retain`). During the
  move the volume is briefly `degraded` (a surviving replica serves) — the precise
  shape of VM-loss-not-host-loss resilience. This is the compute+storage HA boundary
  the README states and demo clip #2 records; it is *not* protection against the
  single Proxmox host failing.

## Rejected alternatives

- **Present 3-way replication as high availability.** It is write-amplification
  on one disk, not redundancy. Claiming HA on a single-host cluster is the exact
  hidden flaw this ADR refuses. Rejected.
- **Skip Longhorn; keep k3s `local-path`.** local-path pins a volume to one node,
  so a rescheduled pod loses its data — it cannot prove FR15 and blocks every
  stateful cutover. It was the Phase-1-only throwaway provisioner. Rejected.
- **Wait for a second physical host before adopting Longhorn.** Blocks all of
  Phase 2c (stateful cutovers) on hardware that may never arrive; the learning
  and pod-mobility value stands on one host today, with the limitation documented.
  Rejected — adopt now, document honestly.

## Exposure note

Safe to show publicly: the topology shape (3 VMs on 1 host), the SPOF reasoning,
and the version pins. No real hostnames, IPs, or the Proxmox host identity appear
here — node names are logical (`k3s-2a-1..3`) and any operational output with real
addresses stays out of committed clips per the
[release checklist](../RELEASE-CHECKLIST.md).
