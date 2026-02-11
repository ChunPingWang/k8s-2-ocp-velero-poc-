#!/usr/bin/env bash
set -euo pipefail

# Phase 5: Restore to OpenShift Local (CRC)
# Restores the demo-app backup from MinIO to the CRC cluster,
# applies post-restore fixups for OpenShift, and validates the restore.

CRC_CONTEXT="default/api-crc-testing:6443/kubeadmin"
CRC_STORAGE_CLASS="crc-csi-hostpath-provisioner"

echo "=== Phase 5: Restore to OpenShift Local ==="

# Step 1: Pre-restore cleanup
echo "[1/6] Cleaning up target namespace..."
oc delete namespace demo-app --ignore-not-found
sleep 5

# Step 2: Restore from backup
echo "[2/6] Restoring from backup..."
velero --kubecontext "${CRC_CONTEXT}" restore create demo-app-restore \
  --from-backup demo-app-backup \
  --wait

# Step 3: Fix PVC storage class (Kind uses 'standard', CRC uses different class)
echo "[3/6] Fixing PVC storage class for CRC..."
oc delete pvc postgres-data -n demo-app 2>/dev/null || true
oc apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: postgres-data
  namespace: demo-app
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: ${CRC_STORAGE_CLASS}
  resources:
    requests:
      storage: 1Gi
EOF

# Step 4: Grant SCC to default service account
echo "[4/6] Granting anyuid SCC to default SA..."
oc adm policy add-scc-to-user anyuid -z default -n demo-app

# Step 5: Restart pods to pick up SCC changes
echo "[5/6] Restarting deployments..."
oc rollout restart deployment/postgres -n demo-app
oc rollout restart deployment/frontend -n demo-app
oc rollout status deployment/postgres -n demo-app --timeout=120s
oc rollout status deployment/frontend -n demo-app --timeout=120s

# Step 6: Validate
echo "[6/6] Validating restore..."
echo ""
echo "--- Resources on CRC ---"
oc get all,pvc,configmap,secret -n demo-app
echo ""
echo "NOTE: Volume data is NOT transferred when source uses hostPath volumes."
echo "      Re-seed data manually if needed for validation."

echo ""
echo "=== Phase 5 Complete: Restore to OpenShift Local successful ==="
