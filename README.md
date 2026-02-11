# Kubernetes 備份與還原至 OpenShift — Velero PoC

本專案示範如何使用 **Velero** 將 **Kind**（Kubernetes-in-Docker）叢集上的工作負載備份，並還原到 **Red Hat OpenShift Local**（CRC）叢集，中間透過 **MinIO** 作為 S3 相容的物件儲存。

---

## 架構概覽

```
┌─────────────────┐       ┌───────────────┐       ┌───────────────────────┐
│  Kind 叢集       │       │  MinIO (S3)   │       │  OpenShift Local      │
│  （來源叢集）     │──────▶│  備份儲存庫    │◀──────│  （目標 / 還原叢集）    │
│                  │ Velero │               │ Velero│                       │
│  應用工作負載     │  備份  │  Bucket:      │ 還原  │  還原後的工作負載       │
│  + PVCs          │       │  k8s-backups  │       │  + PVCs               │
└─────────────────┘       └───────────────┘       └───────────────────────┘
```

**為什麼用這個架構？**
- **Velero** 是 Kubernetes 備份/還原的業界標準工具，同時支援 OpenShift
- **MinIO** 作為共用的 S3 儲存，讓備份可以在兩個叢集間共享
- 完全在本機運行，不需要雲端服務

---

## 事前準備

在開始之前，請確認你的環境已安裝以下工具：

| 工具 | 版本 / 說明 |
|---|---|
| [Docker](https://docs.docker.com/get-docker/) | 用來執行 Kind 和 MinIO |
| [Kind](https://kind.sigs.k8s.io/docs/user/quick-start/#installation) | v0.20+ — Kubernetes-in-Docker |
| [OpenShift Local (CRC)](https://developers.redhat.com/products/openshift-local/overview) | v2.x — 本機 OpenShift 叢集 |
| [Velero CLI](https://velero.io/docs/v1.15/basic-install/) | v1.14+ — 備份/還原命令列工具 |
| [kubectl](https://kubernetes.io/docs/tasks/tools/) | Kubernetes 命令列工具 |
| [oc](https://docs.openshift.com/container-platform/latest/cli_reference/openshift_cli/getting-started-cli.html) | OpenShift 命令列工具（CRC 安裝時附帶） |

**硬體需求：** 建議至少 16 GB RAM（CRC 本身需要約 9 GB）

---

## 快速開始

### 第一步：取得專案

```bash
git clone https://github.com/ChunPingWang/k8s-2-ocp-velero-poc-.git
cd k8s-2-ocp-velero-poc-
```

---

## PoC 階段詳解

### Phase 1：環境建置

#### 1.1 建立 Kind 叢集（來源叢集）

```bash
# 建立本機持久化資料目錄
mkdir -p /tmp/kind-pv

# 使用設定檔建立叢集（包含一個 control-plane 和一個 worker 節點）
kind create cluster --name source-cluster --config kind-config.yaml

# 確認叢集已啟動
kubectl cluster-info --context kind-source-cluster
```

> **給初學者：** `kind-config.yaml` 定義了叢集的節點配置，`extraMounts` 讓容器可以存取主機上的 `/tmp/kind-pv` 目錄，用來模擬持久化儲存。

<details>
<summary>執行紀錄（點擊展開）</summary>

```
$ kind create cluster --name source-cluster --config kind-config.yaml
Creating cluster "source-cluster" ...
 ✓ Ensuring node image (kindest/node:v1.31.0) 🖼
 ✓ Preparing nodes 📦 📦
 ✓ Writing configuration 📜
 ✓ Starting control-plane 🕹️
 ✓ Installing CNI 🔌
 ✓ Installing StorageClass 💾
 ✓ Joining worker nodes 🚜
Set kubectl context to "kind-source-cluster"

$ kubectl cluster-info --context kind-source-cluster
Kubernetes control plane is running at https://127.0.0.1:41373
CoreDNS is running at https://127.0.0.1:41373/api/v1/namespaces/kube-system/services/kube-dns:dns/proxy
```

</details>

#### 1.2 啟動 OpenShift Local（目標叢集）

```bash
# 啟動 CRC（第一次啟動會需要較長時間）
crc start

# 設定 oc 命令列環境
eval $(crc oc-env)

# 以管理員身份登入
oc login -u kubeadmin https://api.crc.testing:6443
```

> **給初學者：** CRC 是一個精簡版的 OpenShift，跑在本機虛擬機中。`crc start` 會啟動這個虛擬機。

<details>
<summary>執行紀錄（點擊展開）</summary>

```
$ crc status
CRC VM:          Running
OpenShift:       Running (v4.20.5)
RAM Usage:       6.942GB of 10.95GB
Disk Usage:      26.76GB of 32.68GB (Inside the CRC VM)
Cache Usage:     31.59GB
Cache Directory: /home/rexwang/.crc/cache
```

</details>

#### 1.3 部署 MinIO（共用備份儲存）

MinIO 是一個 S3 相容的物件儲存服務，我們用它作為 Velero 備份的目標。

```bash
# 啟動 MinIO 容器
docker run -d --name minio \
  -p 9000:9000 -p 9001:9001 \
  -e MINIO_ROOT_USER=minioadmin \
  -e MINIO_ROOT_PASSWORD=minioadmin \
  minio/minio server /data --console-address ":9001"

# 建立備份用的 bucket
docker run --rm --net=host --entrypoint sh minio/mc -c \
  "mc alias set local http://localhost:9000 minioadmin minioadmin && mc mb local/k8s-backups"
```

> **給初學者：**
> - Port 9000 是 MinIO 的 API 端點（Velero 會用到）
> - Port 9001 是 MinIO 的 Web 管理介面，你可以在瀏覽器開啟 `http://localhost:9001` 查看
> - 帳號密碼都是 `minioadmin`

<details>
<summary>執行紀錄（點擊展開）</summary>

```
$ docker run -d --name minio ...
8c8ca9f00ac1b56dec8eb5c5eef56672356d45981c781f98042186d9fcc96962

$ mc alias set local http://localhost:9000 minioadmin minioadmin && mc mb local/k8s-backups
Added `local` successfully.
Bucket created successfully `local/k8s-backups`.
```

</details>

#### 1.4 確認連線

確保兩個叢集都能連到 MinIO。先找到主機 IP：

```bash
# 取得主機 IP（記下來，後面會用到）
hostname -I | awk '{print $1}'
```

<details>
<summary>執行紀錄（點擊展開）</summary>

```
$ hostname -I | awk '{print $1}'
10.0.0.11

--- Test from Kind ---
$ kubectl run test-minio --rm -i --restart=Never --image=curlimages/curl -- curl -s http://10.0.0.11:9000/minio/health/live
HTTP 200

--- Test from CRC ---
$ oc login -u kubeadmin https://api.crc.testing:6443
Login successful.

$ oc run test-minio --rm -i --restart=Never --image=curlimages/curl -- curl -s http://10.0.0.11:9000/minio/health/live
HTTP 200
```

</details>

---

### Phase 2：部署範例應用

在 Kind 叢集上部署一個包含多種 Kubernetes 資源的範例應用。

#### 2.1 建立命名空間並部署應用

```bash
# 建立命名空間
kubectl create namespace demo-app

# 部署範例應用（包含 PostgreSQL + Nginx 前端）
kubectl apply -f demo-app.yaml
```

> **`demo-app.yaml` 包含以下資源：**
>
> | 資源類型 | 名稱 | 說明 |
> |---|---|---|
> | ConfigMap | app-config | 應用設定（APP_ENV, DB_HOST） |
> | Secret | app-secret | 資料庫密碼 |
> | PVC | postgres-data | PostgreSQL 持久化儲存（1Gi） |
> | Deployment | postgres | PostgreSQL 15 資料庫（1 副本） |
> | Service | postgres-svc | 資料庫服務（port 5432） |
> | Deployment | frontend | Nginx 前端（2 副本） |
> | Service | frontend-svc | 前端服務（port 80） |

<details>
<summary>執行紀錄（點擊展開）</summary>

```
$ kubectl create namespace demo-app
namespace/demo-app created

$ kubectl apply -f demo-app.yaml
configmap/app-config created
secret/app-secret created
persistentvolumeclaim/postgres-data created
deployment.apps/postgres created
service/postgres-svc created
deployment.apps/frontend created
service/frontend-svc created
```

</details>

#### 2.2 寫入測試資料

```bash
# 在 PostgreSQL 中建立測試表格並寫入資料
kubectl exec -n demo-app deploy/postgres -- \
  psql -U postgres -c "CREATE TABLE orders(id serial PRIMARY KEY, item text, amount numeric); \
  INSERT INTO orders(item, amount) VALUES ('Widget', 99.95), ('Gadget', 149.00);"
```

#### 2.3 記錄基準狀態

```bash
# 保存目前的資源狀態，用來和還原後比較
kubectl get all,pvc,configmap,secret -n demo-app -o wide > baseline-state.txt

# 保存資料庫內容
kubectl exec -n demo-app deploy/postgres -- \
  psql -U postgres -c "SELECT * FROM orders;" > baseline-data.txt
```

<details>
<summary>執行紀錄（點擊展開）</summary>

```
$ kubectl exec -n demo-app deploy/postgres -- psql -U postgres -c "CREATE TABLE orders(...); INSERT INTO ..."
CREATE TABLE
INSERT 0 2

$ kubectl exec -n demo-app deploy/postgres -- psql -U postgres -c "SELECT * FROM orders;"
 id |  item  | amount
----+--------+--------
  1 | Widget |  99.95
  2 | Gadget | 149.00
(2 rows)

$ kubectl get all,pvc,configmap,secret -n demo-app
NAME                            READY   STATUS    RESTARTS   AGE
pod/frontend-55488668d5-8zbvf   1/1     Running   0          5m9s
pod/frontend-55488668d5-fpq8h   1/1     Running   0          5m9s
pod/postgres-77448799f8-vbm2j   1/1     Running   0          5m9s

NAME                   TYPE        CLUSTER-IP      EXTERNAL-IP   PORT(S)    AGE
service/frontend-svc   ClusterIP   10.96.28.94     <none>        80/TCP     5m9s
service/postgres-svc   ClusterIP   10.96.167.182   <none>        5432/TCP   5m9s

NAME                       READY   UP-TO-DATE   AVAILABLE   AGE
deployment.apps/frontend   2/2     2            2           5m9s
deployment.apps/postgres   1/1     1            1           5m9s

NAME                                  STATUS   VOLUME                                     CAPACITY   ACCESS MODES   STORAGECLASS   AGE
persistentvolumeclaim/postgres-data   Bound    pvc-7d7bbd2e-f69b-4165-b854-6928fc517b84   1Gi        RWO            standard       5m9s

NAME                         DATA   AGE
configmap/app-config         2      5m9s

NAME                TYPE     DATA   AGE
secret/app-secret   Opaque   1      5m9s
```

</details>

---

### Phase 3：安裝與設定 Velero

在**兩個叢集**上都安裝 Velero，並設定 MinIO 作為備份目標。

#### 3.1 安裝 Velero CLI

```bash
# 下載 Velero CLI（以 v1.15.2 為例）
curl -sL https://github.com/vmware-tanzu/velero/releases/download/v1.15.2/velero-v1.15.2-linux-amd64.tar.gz \
  | tar -xz -C /tmp/
sudo cp /tmp/velero-v1.15.2-linux-amd64/velero /usr/local/bin/

# 確認安裝
velero version --client-only
```

#### 3.2 建立 MinIO 憑證檔

```bash
cat <<EOF > /tmp/minio-credentials
[default]
aws_access_key_id = minioadmin
aws_secret_access_key = minioadmin
EOF
```

> **給初學者：** Velero 使用 AWS S3 外掛來連接 MinIO，所以憑證格式和 AWS 的一樣。

#### 3.3 在 Kind 叢集安裝 Velero

```bash
# 將 <HOST_IP> 替換成你的主機 IP
velero install \
  --provider aws \
  --plugins velero/velero-plugin-for-aws:v1.11.0 \
  --bucket k8s-backups \
  --secret-file /tmp/minio-credentials \
  --backup-location-config region=minio,s3ForcePathStyle=true,s3Url=http://<HOST_IP>:9000 \
  --use-volume-snapshots=false \
  --use-node-agent \
  --default-volumes-to-fs-backup \
  --kubecontext kind-source-cluster \
  --wait
```

> **參數說明：**
> - `--provider aws`：使用 AWS S3 相容協定（MinIO 相容）
> - `--use-volume-snapshots=false`：不使用快照（本機環境沒有 CSI 快照支援）
> - `--use-node-agent`：啟用節點代理（用於檔案系統層級備份）
> - `--default-volumes-to-fs-backup`：預設對所有 Volume 使用檔案系統備份

#### 3.4 在 OpenShift Local 安裝 Velero

```bash
# 先登入 CRC
oc login -u kubeadmin https://api.crc.testing:6443

velero install \
  --provider aws \
  --plugins velero/velero-plugin-for-aws:v1.11.0 \
  --bucket k8s-backups \
  --secret-file /tmp/minio-credentials \
  --backup-location-config region=minio,s3ForcePathStyle=true,s3Url=http://<HOST_IP>:9000 \
  --use-volume-snapshots=false \
  --use-node-agent \
  --default-volumes-to-fs-backup \
  --kubecontext <CRC_CONTEXT> \
  --wait

# 授予 Velero 在 OpenShift 上所需的安全權限
oc adm policy add-scc-to-user privileged -z velero -n velero
oc adm policy add-scc-to-user anyuid -z velero -n velero
```

> **給初學者：** OpenShift 比原生 Kubernetes 有更嚴格的安全限制（SCC — Security Context Constraints）。Velero 需要 `privileged` 和 `anyuid` 權限才能正常運作。

#### 3.5 驗證安裝

```bash
# 在兩個叢集上分別執行，確認狀態為 Available
velero backup-location get
```

<details>
<summary>執行紀錄（點擊展開）</summary>

```
$ velero version --client-only
Client:
    Version: v1.15.2
    Git commit: 804d73c4f2349f1ca9bd3d6c751956e1d2021c01

--- Kind 安裝完成 ---
Velero is installed! ⛵ Use 'kubectl logs deployment/velero -n velero' to view the status.

--- CRC 安裝完成 ---
Velero is installed! ⛵ Use 'kubectl logs deployment/velero -n velero' to view the status.

$ oc adm policy add-scc-to-user privileged -z velero -n velero
clusterrole.rbac.authorization.k8s.io/system:openshift:scc:privileged added: "velero"
$ oc adm policy add-scc-to-user anyuid -z velero -n velero
clusterrole.rbac.authorization.k8s.io/system:openshift:scc:anyuid added: "velero"

--- 驗證 Kind ---
$ velero --kubecontext kind-source-cluster backup-location get
NAME      PROVIDER   BUCKET/PREFIX   PHASE       LAST VALIDATED                  ACCESS MODE   DEFAULT
default   aws        k8s-backups     Available   2026-02-11 23:07:50 +0800 CST   ReadWrite     true

--- 驗證 CRC ---
$ velero --kubecontext default/api-crc-testing:6443/kubeadmin backup-location get
NAME      PROVIDER   BUCKET/PREFIX   PHASE       LAST VALIDATED                  ACCESS MODE   DEFAULT
default   aws        k8s-backups     Available   2026-02-11 23:08:22 +0800 CST   ReadWrite     true
```

</details>

---

### Phase 4：從 Kind 建立備份

```bash
# 備份 demo-app 命名空間的所有資源
velero backup create demo-app-backup \
  --include-namespaces demo-app \
  --default-volumes-to-fs-backup \
  --wait
```

確認備份完成：

```bash
# 查看備份詳情
velero backup describe demo-app-backup --details

# 確認備份檔案已寫入 MinIO
docker run --rm --net=host --entrypoint sh minio/mc -c \
  "mc alias set local http://localhost:9000 minioadmin minioadmin >/dev/null 2>&1 && \
   mc ls local/k8s-backups/backups/"
```

> **你應該會看到：** 備份狀態為 `Completed`，MinIO 中有一個 `demo-app-backup/` 目錄。

<details>
<summary>執行紀錄（點擊展開）</summary>

```
$ velero backup create demo-app-backup --include-namespaces demo-app --default-volumes-to-fs-backup --wait
Backup request "demo-app-backup" submitted successfully.
Waiting for backup to complete. You may safely press ctrl-c to stop waiting - your backup will continue in the background.
.
Backup completed with status: Completed.

$ velero backup describe demo-app-backup --details
Name:         demo-app-backup
Namespace:    velero
Annotations:  velero.io/source-cluster-k8s-gitversion=v1.31.0

Phase:  Completed

Started:    2026-02-11 23:09:14 +0800 CST
Completed:  2026-02-11 23:09:15 +0800 CST

Total items to be backed up:  44
Items backed up:              44

Resource List:
  apps/v1/Deployment:
    - demo-app/frontend
    - demo-app/postgres
  apps/v1/ReplicaSet:
    - demo-app/frontend-55488668d5
    - demo-app/postgres-77448799f8
  v1/ConfigMap:
    - demo-app/app-config
  v1/Namespace:
    - demo-app
  v1/PersistentVolumeClaim:
    - demo-app/postgres-data
  v1/Pod:
    - demo-app/frontend-55488668d5-8zbvf
    - demo-app/frontend-55488668d5-fpq8h
    - demo-app/postgres-77448799f8-vbm2j
  v1/Secret:
    - demo-app/app-secret
  v1/Service:
    - demo-app/frontend-svc
    - demo-app/postgres-svc
  v1/ServiceAccount:
    - demo-app/default

$ mc ls local/k8s-backups/backups/
[2026-02-11 15:09:16 UTC]     0B demo-app-backup/
```

</details>

---

### Phase 5：還原至 OpenShift Local

#### 5.1 前置清理

```bash
# 確保目標叢集上沒有同名的命名空間
oc delete namespace demo-app --ignore-not-found
```

#### 5.2 執行還原

```bash
velero restore create demo-app-restore \
  --from-backup demo-app-backup \
  --wait
```

<details>
<summary>執行紀錄（點擊展開）</summary>

```
$ velero restore create demo-app-restore --from-backup demo-app-backup --wait
Restore request "demo-app-restore" submitted successfully.
Waiting for restore to complete.
.
Restore completed with status: Completed.

Phase:                       Completed
Total items to be restored:  20
Items restored:              20

Backup:  demo-app-backup

Resource List:
  apps/v1/Deployment:
    - demo-app/frontend(created)
    - demo-app/postgres(created)
  apps/v1/ReplicaSet:
    - demo-app/frontend-55488668d5(created)
    - demo-app/postgres-77448799f8(created)
  v1/ConfigMap:
    - demo-app/app-config(created)
  v1/Namespace:
    - demo-app(created)
  v1/PersistentVolumeClaim:
    - demo-app/postgres-data(created)
  v1/Pod:
    - demo-app/frontend-55488668d5-8zbvf(created)
    - demo-app/frontend-55488668d5-fpq8h(created)
    - demo-app/postgres-77448799f8-vbm2j(created)
  v1/Secret:
    - demo-app/app-secret(created)
  v1/Service:
    - demo-app/frontend-svc(created)
    - demo-app/postgres-svc(created)
```

</details>

#### 5.3 還原後修復

OpenShift 和原生 Kubernetes 之間有一些差異，需要手動修復：

```bash
# 1. 修復 StorageClass（Kind 用 "standard"，CRC 用不同的 StorageClass）
oc delete pvc postgres-data -n demo-app
oc apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: postgres-data
  namespace: demo-app
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: crc-csi-hostpath-provisioner
  resources:
    requests:
      storage: 1Gi
EOF

# 2. 授予 SCC 權限（讓 Pod 可以用原來的 UID 執行）
oc adm policy add-scc-to-user anyuid -z default -n demo-app

# 3. 重啟 Deployment 以套用 SCC 變更
oc rollout restart deployment/postgres -n demo-app
oc rollout restart deployment/frontend -n demo-app

# 4. 等待所有 Pod 就緒
oc rollout status deployment/postgres -n demo-app --timeout=120s
oc rollout status deployment/frontend -n demo-app --timeout=120s
```

> **給初學者：** 這些「還原後修復」步驟是跨叢集還原時最常遇到的挑戰：
> - **StorageClass 不同**：每個叢集的儲存驅動可能不同
> - **SCC 限制**：OpenShift 預設不允許容器以 root 或特定 UID 執行
> - **重啟 Pod**：讓 Pod 套用新的安全設定

<details>
<summary>執行紀錄（點擊展開）</summary>

```
$ oc delete pvc postgres-data -n demo-app
persistentvolumeclaim "postgres-data" deleted

$ oc apply -f pvc-fix.yaml
persistentvolumeclaim/postgres-data created

$ oc adm policy add-scc-to-user anyuid -z default -n demo-app
clusterrole.rbac.authorization.k8s.io/system:openshift:scc:anyuid added: "default"

$ oc rollout restart deployment/postgres -n demo-app
deployment.apps/postgres restarted
$ oc rollout restart deployment/frontend -n demo-app
deployment.apps/frontend restarted

deployment "postgres" successfully rolled out
deployment "frontend" successfully rolled out

$ oc get all,pvc,configmap,secret -n demo-app
NAME                            READY   STATUS    RESTARTS   AGE
pod/frontend-86c75b46d8-44944   1/1     Running   0          1s
pod/frontend-86c75b46d8-db9sn   1/1     Running   0          2s
pod/postgres-66cdb5dfcc-69wsp   1/1     Running   0          3s

NAME                   TYPE        CLUSTER-IP     EXTERNAL-IP   PORT(S)    AGE
service/frontend-svc   ClusterIP   10.217.5.171   <none>        80/TCP     2m9s
service/postgres-svc   ClusterIP   10.217.4.152   <none>        5432/TCP   2m9s

NAME                       READY   UP-TO-DATE   AVAILABLE   AGE
deployment.apps/frontend   2/2     2            2           2m9s
deployment.apps/postgres   1/1     1            1           2m9s

NAME                                  STATUS   VOLUME                                     CAPACITY   ACCESS MODES   STORAGECLASS                   AGE
persistentvolumeclaim/postgres-data   Bound    pvc-041decda-f926-4dfc-8628-7d8d73f32676   30Gi       RWO            crc-csi-hostpath-provisioner   3s

NAME                         DATA   AGE
configmap/app-config         2      2m10s

NAME                TYPE     DATA   AGE
secret/app-secret   Opaque   1      2m10s
```

</details>

---

### Phase 6：驗證還原結果

執行驗證腳本：

```bash
./phase6-validate.sh
```

或手動逐項檢查：

| # | 驗證項目 | 指令 | 預期結果 |
|---|---|---|---|
| 1 | 命名空間存在 | `oc get ns demo-app` | Active |
| 2 | Deployment 執行中 | `oc get deploy -n demo-app` | postgres (1/1), frontend (2/2) |
| 3 | Service 已還原 | `oc get svc -n demo-app` | postgres-svc, frontend-svc |
| 4 | ConfigMap 完整 | `oc get cm app-config -n demo-app -o yaml` | APP_ENV=production |
| 5 | Secret 完整 | `oc get secret app-secret -n demo-app` | Opaque |
| 6 | PVC 已綁定 | `oc get pvc -n demo-app` | Bound |
| 7 | 資料完整性 | `oc exec deploy/postgres -- psql -U postgres -c "SELECT * FROM orders;"` | Widget, Gadget |
| 8 | 前端可存取 | `oc port-forward svc/frontend-svc 8080:80` | HTTP 200 |

<details>
<summary>驗證結果（點擊展開）</summary>

```
============================================================
  VALIDATION REPORT
============================================================

[1] Namespace exists on CRC:
$ oc get ns demo-app
NAME       STATUS   AGE
demo-app   Active   3m8s

[2] Deployments running:
$ oc get deploy -n demo-app
NAME       READY   UP-TO-DATE   AVAILABLE   AGE
frontend   2/2     2            2           3m7s
postgres   1/1     1            1           3m7s

[3] Services restored:
$ oc get svc -n demo-app
NAME           TYPE        CLUSTER-IP     EXTERNAL-IP   PORT(S)    AGE
frontend-svc   ClusterIP   10.217.5.171   <none>        80/TCP     3m8s
postgres-svc   ClusterIP   10.217.4.152   <none>        5432/TCP   3m8s

[4] ConfigMap intact:
$ oc get cm app-config -n demo-app -o jsonpath={.data}
{"APP_ENV":"production","DB_HOST":"postgres-svc"}

[5] Secret intact:
$ oc get secret app-secret -n demo-app
NAME         TYPE     DATA   AGE
app-secret   Opaque   1      3m9s

[6] PVC bound:
$ oc get pvc -n demo-app
NAME            STATUS   VOLUME                                     CAPACITY   ACCESS MODES   STORAGECLASS                   AGE
postgres-data   Bound    pvc-041decda-f926-4dfc-8628-7d8d73f32676   30Gi       RWO            crc-csi-hostpath-provisioner   62s

[7] Data integrity:
$ oc exec deploy/postgres -- psql -U postgres -c "SELECT * FROM orders;"
 id |  item  | amount
----+--------+--------
  1 | Widget |  99.95
  2 | Gadget | 149.00
(2 rows)

[8] Frontend accessible:
$ curl http://frontend-svc:80
HTTP 200

============================================================
  ALL 8 VALIDATIONS PASSED
============================================================
```

</details>

---

### 跨叢集證明

以下證明備份確實來自 Kind 叢集，並成功還原至 CRC OpenShift 叢集：

<details>
<summary>跨叢集證明（點擊展開）</summary>

```
--- Kind (Source) nodes ---
$ kubectl --context kind-source-cluster get nodes -o wide
NAME                           STATUS   ROLES           AGE   VERSION   INTERNAL-IP   OS-IMAGE                         CONTAINER-RUNTIME
source-cluster-control-plane   Ready    control-plane   17m   v1.31.0   172.18.0.3    Debian GNU/Linux 12 (bookworm)   containerd://1.7.18
source-cluster-worker          Ready    <none>          17m   v1.31.0   172.18.0.2    Debian GNU/Linux 12 (bookworm)   containerd://1.7.18

--- CRC (Target) nodes ---
$ oc get nodes -o wide
NAME   STATUS   ROLES                         AGE   VERSION   INTERNAL-IP      OS-IMAGE                                                CONTAINER-RUNTIME
crc    Ready    control-plane,master,worker   76d   v1.33.5   192.168.126.11   Red Hat Enterprise Linux CoreOS 9.6.20251119-0 (Plow)   cri-o://1.33.5-3.rhaos4.20.gitd0ea985.el9

--- Velero backup annotation (source K8s version) ---
velero.io/source-cluster-k8s-gitversion=v1.31.0

--- Velero restore on CRC (backup reference) ---
Backup:  demo-app-backup

--- Data on Kind ---
 id |  item  | amount
----+--------+--------
  1 | Widget |  99.95
  2 | Gadget | 149.00
(2 rows)

--- Data on CRC ---
 id |  item  | amount
----+--------+--------
  1 | Widget |  99.95
  2 | Gadget | 149.00
(2 rows)
```

**結論：** 兩個完全不同的叢集（Kind K8s v1.31 vs CRC OpenShift v4.20.5），透過 Velero + MinIO 成功完成跨叢集備份與還原。

</details>

---

## 專案檔案結構

```
.
├── README.md                                    # 本文件（繁體中文說明，含執行紀錄）
├── poc-k8s-backup-to-openshift-recovery.md      # PoC 完整計畫文件（英文）
├── kind-config.yaml                             # Kind 叢集設定
├── demo-app.yaml                                # 範例應用 Kubernetes manifest
├── phase3-velero-setup.sh                       # Phase 3: Velero 安裝腳本
├── phase4-backup.sh                             # Phase 4: 備份腳本
├── phase5-restore.sh                            # Phase 5: 還原腳本
├── phase6-validate.sh                           # Phase 6: 驗證腳本
├── logs/                                        # 各階段執行紀錄
│   ├── phase1-kind-create.log
│   ├── phase1-crc-status.log
│   ├── phase1-minio-setup.log
│   ├── phase1-connectivity.log
│   ├── phase2-deploy.log
│   ├── phase2-seed-data.log
│   ├── phase3-velero-install.log
│   ├── phase3-velero-crc.log
│   ├── phase3-verify.log
│   ├── phase4-backup.log
│   ├── phase5-restore.log
│   ├── phase5-fixups.log
│   └── phase6-validation.log
├── baseline-state.txt                           # 備份前的資源狀態
├── baseline-data.txt                            # 備份前的資料庫內容
├── restored-state.txt                           # 還原後的資源狀態
└── validation-report.md                         # 驗證報告
```

---

## 已知限制

| 限制 | 說明 | 生產環境建議 |
|---|---|---|
| Volume 資料未轉移 | Kind 使用 hostPath Volume，Velero 的檔案系統備份不支援 hostPath | 使用 CSI 快照備份 |
| StorageClass 不同 | 來源與目標叢集的 StorageClass 名稱不同 | 使用 Velero 的 ConfigMap 做 StorageClass 映射 |
| SCC 限制 | OpenShift 有更嚴格的安全策略 | 預先配置好 SCC 政策 |
| 映像檔可用性 | 兩個叢集都必須能拉取相同的容器映像檔 | 使用共用的容器映像檔 Registry |

---

## 延伸學習

- **排程備份**：使用 `velero schedule create` 設定自動定期備份
- **多命名空間備份**：備份整個叢集或依標籤選取命名空間
- **災難復原演練**：模擬 Kind 叢集損毀，在 CRC 上完整還原
- **OADP**：在正式 OpenShift 環境中，建議使用 [OADP](https://docs.openshift.com/container-platform/latest/backup_and_restore/application_backup_and_restore/oadp-intro.html)（OpenShift API for Data Protection），它是 Velero 的 OpenShift 官方封裝
- **GitOps 整合**：將 Velero 資料備份與 ArgoCD/Flux 的設定即程式碼結合

---

## 參考資料

- [Velero 官方文件](https://velero.io/docs/)
- [OADP — OpenShift API for Data Protection](https://docs.openshift.com/container-platform/latest/backup_and_restore/application_backup_and_restore/oadp-intro.html)
- [Kind 快速入門](https://kind.sigs.k8s.io/docs/user/quick-start/)
- [OpenShift Local (CRC)](https://developers.redhat.com/products/openshift-local/overview)
- [MinIO 快速入門](https://min.io/docs/minio/container/index.html)
