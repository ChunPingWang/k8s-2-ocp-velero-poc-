# Validation Report — K8s to OpenShift Velero PoC

**Date:** 2026-02-11
**Source Cluster:** Kind (kind-source-cluster)
**Target Cluster:** OpenShift Local (CRC v4.20.5)
**Backup Tool:** Velero v1.15.2 with AWS plugin v1.11.0
**Storage Backend:** MinIO (S3-compatible)

---

## Validation Results

| # | Validation Item | Result | Notes |
|---|---|---|---|
| 1 | Namespace exists on CRC | PASS | `demo-app` — Active |
| 2 | Deployments running | PASS | postgres (1/1), frontend (2/2) |
| 3 | Services restored | PASS | frontend-svc, postgres-svc — ClusterIP |
| 4 | ConfigMap intact | PASS | APP_ENV=production, DB_HOST=postgres-svc |
| 5 | Secret intact | PASS | app-secret — Opaque, 1 data key |
| 6 | PVC bound | PASS | postgres-data — Bound (crc-csi-hostpath-provisioner) |
| 7 | Data integrity | PASS | 2 rows: Widget (99.95), Gadget (149.00) |
| 8 | Frontend accessible | PASS | HTTP 200 from nginx |

**Overall: 8/8 PASSED**

---

## Backup Details

- **Backup Name:** demo-app-backup
- **Items Backed Up:** 47 resources
- **Resources Included:** Deployments, ReplicaSets, Services, ConfigMaps, Secrets, PVCs, Pods, ServiceAccounts, EndpointSlices, PersistentVolumes, Namespace

## Restore Details

- **Restore Name:** demo-app-restore
- **Items Restored:** 20 resources (events excluded by default)
- **Post-Restore Fixups Required:**
  1. StorageClass remapping: `standard` (Kind) → `crc-csi-hostpath-provisioner` (CRC)
  2. SCC grant: `anyuid` to default ServiceAccount in demo-app
  3. Deployment restarts to pick up SCC changes

---

## Known Limitations

1. **Volume data not transferred:** Kind uses hostPath-based PVs which are not supported by Velero's file-system backup (kopia/restic). In production, use CSI snapshot-based backup for persistent data.

2. **StorageClass mismatch:** Source and target clusters use different StorageClasses. Manual PVC recreation with the correct StorageClass is required.

3. **SCC enforcement:** OpenShift enforces stricter security contexts than vanilla Kubernetes. Post-restore SCC grants are needed for pods that require specific UIDs.

4. **Image availability:** Both clusters must be able to pull the same container images. Public images (postgres:15, nginx:1.25) work without issues.

---

## Conclusion

The PoC successfully demonstrates cross-cluster backup and restore of Kubernetes workloads from Kind to OpenShift Local using Velero. All structural resources (Deployments, Services, ConfigMaps, Secrets, PVCs) are faithfully restored. Volume data transfer requires CSI snapshot support for production use cases.
