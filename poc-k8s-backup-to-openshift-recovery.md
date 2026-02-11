# PoC Plan: Kubernetes Backup & Recovery to OpenShift Local

## 1. Objective

Demonstrate a cross-cluster backup and restore workflow: back up workloads running on a **Kind** (Kubernetes-in-Docker) cluster and recover them onto a **Red Hat OpenShift Local** (CRC) cluster using **Velero** as the backup/restore engine with a **MinIO** S3-compatible object store as the shared backup target.

---

## 2. Architecture Overview

```
┌─────────────────┐       ┌───────────────┐       ┌───────────────────────┐
│  Kind Cluster    │       │  MinIO (S3)   │       │  OpenShift Local      │
│  (Source)        │──────▶│  Backup Repo  │◀──────│  (Target / Recovery)  │
│                  │ Velero │               │ Velero│                       │
│  App Workloads   │ backup │  Bucket:      │restore│  Restored Workloads   │
│  + PVCs          │       │  k8s-backups  │       │  + PVCs               │
└─────────────────┘       └───────────────┘       └───────────────────────┘
```

**Why this approach?** Velero is the de-facto standard for Kubernetes backup/restore and is fully supported on OpenShift. Using MinIO as a shared intermediary avoids cloud dependencies and keeps the PoC entirely local.

---

## 3. Prerequisites

| Component | Version / Notes |
|---|---|
| Kind | v0.20+ installed, Docker running |
| OpenShift Local (CRC) | v2.x started (`crc start`) |
| Velero CLI | v1.14+ |
| MinIO (Docker) | Latest (`minio/minio`) |
| Helm | v3.x (for optional chart-based installs) |
| kubectl / oc | Both configured for respective clusters |
| OS | RHEL / Fedora / macOS with sufficient RAM (≥16 GB recommended) |

---

## 4. PoC Phases

### Phase 1: Environment Setup (Day 1)

**4.1.1 — Start Kind Cluster**

```bash
# kind-config.yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
  - role: worker
    extraMounts:
      - hostPath: /tmp/kind-pv
        containerPath: /data

kind create cluster --name source-cluster --config kind-config.yaml
kubectl cluster-info --context kind-source-cluster
```

**4.1.2 — Start OpenShift Local**

```bash
crc start
eval $(crc oc-env)
oc login -u kubeadmin https://api.crc.testing:6443
```

**4.1.3 — Deploy MinIO as Shared Backup Target**

Run MinIO on the host Docker network so both clusters can reach it.

```bash
docker run -d --name minio \
  -p 9000:9000 -p 9001:9001 \
  -e MINIO_ROOT_USER=minioadmin \
  -e MINIO_ROOT_PASSWORD=minioadmin \
  minio/minio server /data --console-address ":9001"

# Create the backup bucket
docker run --rm --net=host \
  minio/mc alias set local http://localhost:9000 minioadmin minioadmin && \
  minio/mc mb local/k8s-backups
```

**4.1.4 — Verify Connectivity**

Confirm both clusters can reach MinIO at `http://<host-ip>:9000`. For Kind, use the Docker bridge IP; for CRC, use the host IP visible from the CRC VM.

---

### Phase 2: Deploy Sample Workloads on Kind (Day 1–2)

Deploy a representative workload that exercises Deployments, Services, ConfigMaps, Secrets, and PersistentVolumeClaims.

**4.2.1 — Create Namespace and Application**

```bash
kubectl create namespace demo-app
```

**4.2.2 — Sample Workload Manifest (demo-app.yaml)**

```yaml
# ConfigMap
apiVersion: v1
kind: ConfigMap
metadata:
  name: app-config
  namespace: demo-app
data:
  APP_ENV: "production"
  DB_HOST: "postgres-svc"
---
# Secret
apiVersion: v1
kind: Secret
metadata:
  name: app-secret
  namespace: demo-app
type: Opaque
stringData:
  DB_PASSWORD: "poc-secret-123"
---
# PVC
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: postgres-data
  namespace: demo-app
spec:
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 1Gi
---
# PostgreSQL Deployment
apiVersion: apps/v1
kind: Deployment
metadata:
  name: postgres
  namespace: demo-app
spec:
  replicas: 1
  selector:
    matchLabels: { app: postgres }
  template:
    metadata:
      labels: { app: postgres }
    spec:
      containers:
        - name: postgres
          image: postgres:15
          ports: [{ containerPort: 5432 }]
          env:
            - name: POSTGRES_PASSWORD
              valueFrom:
                secretKeyRef: { name: app-secret, key: DB_PASSWORD }
          volumeMounts:
            - name: pgdata
              mountPath: /var/lib/postgresql/data
      volumes:
        - name: pgdata
          persistentVolumeClaim: { claimName: postgres-data }
---
# PostgreSQL Service
apiVersion: v1
kind: Service
metadata:
  name: postgres-svc
  namespace: demo-app
spec:
  selector: { app: postgres }
  ports: [{ port: 5432, targetPort: 5432 }]
---
# Frontend Deployment (nginx)
apiVersion: apps/v1
kind: Deployment
metadata:
  name: frontend
  namespace: demo-app
spec:
  replicas: 2
  selector:
    matchLabels: { app: frontend }
  template:
    metadata:
      labels: { app: frontend }
    spec:
      containers:
        - name: nginx
          image: nginx:1.25
          ports: [{ containerPort: 80 }]
          envFrom:
            - configMapRef: { name: app-config }
---
# Frontend Service
apiVersion: v1
kind: Service
metadata:
  name: frontend-svc
  namespace: demo-app
spec:
  selector: { app: frontend }
  ports: [{ port: 80, targetPort: 80 }]
```

```bash
kubectl apply -f demo-app.yaml
```

**4.2.3 — Seed Test Data**

```bash
kubectl exec -n demo-app deploy/postgres -- \
  psql -U postgres -c "CREATE TABLE orders(id serial PRIMARY KEY, item text, amount numeric); \
  INSERT INTO orders(item, amount) VALUES ('Widget', 99.95), ('Gadget', 149.00);"
```

**4.2.4 — Record Baseline State**

```bash
kubectl get all,pvc,configmap,secret -n demo-app -o wide > /tmp/baseline-state.txt
kubectl exec -n demo-app deploy/postgres -- psql -U postgres -c "SELECT * FROM orders;" > /tmp/baseline-data.txt
```

---

### Phase 3: Install & Configure Velero (Day 2)

**4.3.1 — Prepare Velero Credentials**

```bash
cat <<EOF > /tmp/minio-credentials
[default]
aws_access_key_id = minioadmin
aws_secret_access_key = minioadmin
EOF
```

**4.3.2 — Install Velero on Kind (Source Cluster)**

```bash
velero install \
  --provider aws \
  --plugins velero/velero-plugin-for-aws:v1.10.0 \
  --bucket k8s-backups \
  --secret-file /tmp/minio-credentials \
  --backup-storage-location-config \
    region=minio,s3ForcePathStyle=true,s3Url=http://<HOST_IP>:9000 \
  --use-volume-snapshots=false \
  --kubecontext kind-source-cluster
```

**4.3.3 — Install Velero on OpenShift Local (Target Cluster)**

```bash
# Switch context
oc login -u kubeadmin https://api.crc.testing:6443

velero install \
  --provider aws \
  --plugins velero/velero-plugin-for-aws:v1.10.0 \
  --bucket k8s-backups \
  --secret-file /tmp/minio-credentials \
  --backup-storage-location-config \
    region=minio,s3ForcePathStyle=true,s3Url=http://<HOST_IP>:9000 \
  --use-volume-snapshots=false

# Grant Velero the required SCCs on OpenShift
oc adm policy add-scc-to-user privileged -z velero -n velero
oc adm policy add-scc-to-user anyuid -z velero -n velero
```

**4.3.4 — Verify Both Installations**

```bash
velero backup-location get   # Run against each context
```

---

### Phase 4: Backup from Kind (Day 2–3)

**4.4.1 — Create Namespace Backup**

```bash
# Context: Kind
velero backup create demo-app-backup \
  --include-namespaces demo-app \
  --default-volumes-to-fs-backup \
  --wait
```

**4.4.2 — Verify Backup**

```bash
velero backup describe demo-app-backup --details
velero backup logs demo-app-backup

# Confirm backup exists in MinIO
docker run --rm --net=host minio/mc ls local/k8s-backups/backups/
```

---

### Phase 5: Restore to OpenShift Local (Day 3)

**4.5.1 — Pre-Restore: Handle OpenShift Specifics**

OpenShift adds SecurityContextConstraints (SCCs) and may inject different UIDs. Prepare a restore with appropriate mappings.

```bash
# Context: OpenShift Local
# Ensure the target namespace does not exist
oc delete namespace demo-app --ignore-not-found
```

**4.5.2 — Restore**

```bash
velero restore create demo-app-restore \
  --from-backup demo-app-backup \
  --wait
```

**4.5.3 — Post-Restore Fixups**

```bash
# Fix SCC issues — grant anyuid to the demo-app service accounts
oc adm policy add-scc-to-user anyuid -z default -n demo-app

# Restart pods to pick up SCC changes
oc rollout restart deployment/postgres -n demo-app
oc rollout restart deployment/frontend -n demo-app

# If images need to pull from registries, ensure image pull secrets are configured
```

**4.5.4 — Validate Restore**

```bash
# Compare resource state
oc get all,pvc,configmap,secret -n demo-app -o wide > /tmp/restored-state.txt
diff /tmp/baseline-state.txt /tmp/restored-state.txt

# Validate data integrity
oc exec -n demo-app deploy/postgres -- psql -U postgres -c "SELECT * FROM orders;"
# Expected: Widget 99.95, Gadget 149.00
```

---

### Phase 6: Validation & Reporting (Day 3–4)

**4.6.1 — Validation Checklist**

| # | Validation Item | Method | Expected Result |
|---|---|---|---|
| 1 | Namespace exists on CRC | `oc get ns demo-app` | Active |
| 2 | Deployments running | `oc get deploy -n demo-app` | postgres (1/1), frontend (2/2) |
| 3 | Services restored | `oc get svc -n demo-app` | postgres-svc, frontend-svc |
| 4 | ConfigMap intact | `oc get cm app-config -n demo-app -o yaml` | APP_ENV=production |
| 5 | Secret intact | `oc get secret app-secret -n demo-app` | Exists, Opaque |
| 6 | PVC bound | `oc get pvc -n demo-app` | postgres-data = Bound |
| 7 | Data integrity | `SELECT * FROM orders;` | 2 rows: Widget, Gadget |
| 8 | Frontend accessible | `oc port-forward svc/frontend-svc 8080:80` | HTTP 200 |

**4.6.2 — Known Gaps / Limitations**

- **Volume snapshots**: This PoC uses Velero's file-system backup (`restic`/`kopia`). Production environments should evaluate CSI snapshot-based backup for better RPO.
- **Image references**: If Kind uses locally-built images not available in a registry, pods will fail `ImagePullBackOff` on CRC. Use a shared registry for production scenarios.
- **OpenShift-specific resources**: Routes, DeploymentConfigs, and BuildConfigs do not exist on vanilla K8s and won't be part of this backup. This PoC covers the K8s → OpenShift direction only.
- **SCC / UID mapping**: OpenShift enforces stricter security contexts. Post-restore SCC fixups may be required per workload.
- **Networking**: Service types (NodePort, LoadBalancer) and Ingress configurations may need adjustment on the target cluster.

---

## 5. Timeline Summary

| Day | Activity |
|---|---|
| Day 1 | Environment setup (Kind, CRC, MinIO), deploy sample workloads |
| Day 2 | Install Velero on both clusters, create and verify backup |
| Day 3 | Restore to OpenShift Local, post-restore fixups, validation |
| Day 4 | Documentation, demo walkthrough, findings report |

---

## 6. Extension Ideas (Post-PoC)

- **Scheduled backups**: Configure Velero schedules (`velero schedule create`) with retention policies for automated backup cycles.
- **Multi-namespace backup**: Extend to back up the entire cluster or label-selected namespaces.
- **Disaster Recovery drill**: Simulate Kind cluster destruction and full recovery on CRC.
- **Kasten K10 comparison**: Run a parallel PoC with Veeam Kasten K10 to compare operator-based backup UX, policy management, and OpenShift integration.
- **GitOps integration**: Combine Velero data backups with ArgoCD/Flux for application definition recovery (config-as-code + data backup).
- **Cross-cloud restore**: Replace MinIO with AWS S3 or Azure Blob to validate cloud-based backup targets.

---

## 7. References

- [Velero Documentation](https://velero.io/docs/)
- [Velero on OpenShift](https://docs.openshift.com/container-platform/latest/backup_and_restore/application_backup_and_restore/oadp-intro.html) (OADP — OpenShift API for Data Protection)
- [Kind Quick Start](https://kind.sigs.k8s.io/docs/user/quick-start/)
- [OpenShift Local (CRC)](https://developers.redhat.com/products/openshift-local/overview)
- [MinIO Quick Start](https://min.io/docs/minio/container/index.html)
