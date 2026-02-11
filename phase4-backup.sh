#!/usr/bin/env bash
set -euo pipefail

# Phase 4: Backup from Kind
# Creates a Velero backup of the demo-app namespace from the Kind source cluster.

KIND_CONTEXT="kind-source-cluster"

echo "=== Phase 4: Backup from Kind ==="

# Step 1: Create namespace backup
echo "[1/3] Creating backup of demo-app namespace..."
velero --kubecontext "${KIND_CONTEXT}" backup create demo-app-backup \
  --include-namespaces demo-app \
  --default-volumes-to-fs-backup \
  --wait

# Step 2: Verify backup details
echo ""
echo "[2/3] Backup details:"
velero --kubecontext "${KIND_CONTEXT}" backup describe demo-app-backup --details

# Step 3: Confirm backup in MinIO
echo ""
echo "[3/3] Checking backup in MinIO..."
docker run --rm --net=host --entrypoint sh minio/mc -c \
  "mc alias set local http://localhost:9000 minioadmin minioadmin >/dev/null 2>&1 && mc ls local/k8s-backups/backups/"

echo ""
echo "=== Phase 4 Complete: Backup created successfully ==="
