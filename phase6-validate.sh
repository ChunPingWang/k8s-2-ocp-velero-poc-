#!/usr/bin/env bash
set -euo pipefail

# Phase 6: Validation & Reporting
# Runs the full validation checklist against the restored demo-app on CRC.

echo "=== Phase 6: Validation Checklist ==="
echo ""

PASS=0
FAIL=0

check() {
  local num="$1" desc="$2"
  shift 2
  if "$@" > /dev/null 2>&1; then
    echo "[${num}] PASS: ${desc}"
    ((PASS++))
  else
    echo "[${num}] FAIL: ${desc}"
    ((FAIL++))
  fi
}

# 1. Namespace exists
check 1 "Namespace demo-app exists on CRC" oc get ns demo-app

# 2. Deployments running
echo -n "[2] "; oc get deploy -n demo-app --no-headers 2>&1 | while read name ready _; do
  echo -n "Deployment ${name}=${ready} "; done; echo ""
check 2 "Deployments are available" bash -c \
  '[[ $(oc get deploy -n demo-app -o jsonpath="{.items[*].status.availableReplicas}") == "2 1" ]]'

# 3. Services restored
check 3 "Services frontend-svc and postgres-svc exist" bash -c \
  'oc get svc frontend-svc postgres-svc -n demo-app'

# 4. ConfigMap intact
check 4 "ConfigMap app-config has APP_ENV=production" bash -c \
  '[[ $(oc get cm app-config -n demo-app -o jsonpath="{.data.APP_ENV}") == "production" ]]'

# 5. Secret intact
check 5 "Secret app-secret exists (Opaque)" bash -c \
  '[[ $(oc get secret app-secret -n demo-app -o jsonpath="{.type}") == "Opaque" ]]'

# 6. PVC bound
check 6 "PVC postgres-data is Bound" bash -c \
  '[[ $(oc get pvc postgres-data -n demo-app -o jsonpath="{.status.phase}") == "Bound" ]]'

# 7. Data integrity
check 7 "PostgreSQL data: Widget + Gadget rows" bash -c \
  'oc exec -n demo-app deploy/postgres -- psql -U postgres -t -c "SELECT count(*) FROM orders;" 2>/dev/null | grep -q 2'

# 8. Frontend accessible
check 8 "Frontend returns HTTP 200" bash -c \
  'oc exec -n demo-app deploy/frontend -- curl -sf http://localhost:80 > /dev/null 2>&1'

echo ""
echo "=== Results: ${PASS} passed, ${FAIL} failed ==="

if [[ ${FAIL} -gt 0 ]]; then
  echo "Some validations failed. Review the output above."
  exit 1
fi

echo ""
echo "=== Phase 6 Complete: All validations passed ==="
