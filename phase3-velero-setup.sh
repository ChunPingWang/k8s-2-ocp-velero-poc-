#!/usr/bin/env bash
set -euo pipefail

# Phase 3: Install & Configure Velero on both clusters
# This script installs Velero on Kind (source) and OpenShift Local (target)
# with MinIO as the shared S3-compatible backup target.

HOST_IP="${HOST_IP:-10.0.0.11}"
KIND_CONTEXT="kind-source-cluster"
CRC_CONTEXT="default/api-crc-testing:6443/kubeadmin"
VELERO_PLUGIN="velero/velero-plugin-for-aws:v1.11.0"
BUCKET="k8s-backups"

echo "=== Phase 3: Install & Configure Velero ==="

# Step 1: Create MinIO credentials file
echo "[1/5] Creating MinIO credentials file..."
cat <<EOF > /tmp/minio-credentials
[default]
aws_access_key_id = minioadmin
aws_secret_access_key = minioadmin
EOF

# Step 2: Install Velero on Kind (Source Cluster)
echo "[2/5] Installing Velero on Kind (source cluster)..."
velero install \
  --provider aws \
  --plugins "${VELERO_PLUGIN}" \
  --bucket "${BUCKET}" \
  --secret-file /tmp/minio-credentials \
  --backup-location-config "region=minio,s3ForcePathStyle=true,s3Url=http://${HOST_IP}:9000" \
  --use-volume-snapshots=false \
  --use-node-agent \
  --default-volumes-to-fs-backup \
  --kubecontext "${KIND_CONTEXT}" \
  --wait

# Step 3: Install Velero on OpenShift Local (Target Cluster)
echo "[3/5] Installing Velero on OpenShift Local (target cluster)..."
velero install \
  --provider aws \
  --plugins "${VELERO_PLUGIN}" \
  --bucket "${BUCKET}" \
  --secret-file /tmp/minio-credentials \
  --backup-location-config "region=minio,s3ForcePathStyle=true,s3Url=http://${HOST_IP}:9000" \
  --use-volume-snapshots=false \
  --use-node-agent \
  --default-volumes-to-fs-backup \
  --kubecontext "${CRC_CONTEXT}" \
  --wait

# Step 4: Grant SCCs on OpenShift
echo "[4/5] Granting SCCs to Velero on OpenShift..."
oc adm policy add-scc-to-user privileged -z velero -n velero
oc adm policy add-scc-to-user anyuid -z velero -n velero

# Step 5: Verify both installations
echo "[5/5] Verifying Velero installations..."
echo ""
echo "--- Kind (Source) Backup Location ---"
velero --kubecontext "${KIND_CONTEXT}" backup-location get
echo ""
echo "--- OpenShift Local (Target) Backup Location ---"
velero --kubecontext "${CRC_CONTEXT}" backup-location get

echo ""
echo "=== Phase 3 Complete: Velero installed on both clusters ==="
