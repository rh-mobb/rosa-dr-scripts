#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: restore-dr-workload.sh

Creates an OADP Restore from BACKUP_NAME, waits for completion, then applies
DR-specific service-account IAM annotations and S3/region environment values.

Run while logged in to the DR cluster.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 1 ;;
  esac
done

: "${DR_CLUSTER_NAME:?}"
: "${DR_REGION:?}"
: "${BACKUP_NAME:?}"
: "${APP_BUCKET_DR:?}"
: "${APP_S3_ROLE_ARN_DR:?}"

oc whoami >/dev/null

RESTORE_NAME="dr-restore-$(date +%Y%m%d-%H%M)"
export RESTORE_NAME
echo "export RESTORE_NAME=$RESTORE_NAME"

echo "Creating OADP Restore ${RESTORE_NAME} on ${DR_CLUSTER_NAME}." >&2

cat <<EOF | oc apply -f - >&2
apiVersion: velero.io/v1
kind: Restore
metadata:
  name: ${RESTORE_NAME}
  namespace: openshift-adp
spec:
  backupName: ${BACKUP_NAME}
  includedNamespaces:
    - dr-demo
  excludedResources:
    - pods
    - replicasets.apps
    - persistentvolumes
    - persistentvolumeclaims
  restorePVs: false
  existingResourcePolicy: update
EOF

for attempt in $(seq 1 60); do
  phase=$(oc get restore -n openshift-adp "$RESTORE_NAME" -o jsonpath='{.status.phase}' 2>/dev/null || true)
  phase=${phase:-Pending}
  printf '[%s] restore/%s phase=%s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$RESTORE_NAME" "$phase" >&2
  case "$phase" in
    Completed) break ;;
    Failed|PartiallyFailed)
      oc describe restore -n openshift-adp "$RESTORE_NAME" >&2 || true
      exit 1
      ;;
  esac
  if [ "$attempt" -eq 60 ]; then
    oc describe restore -n openshift-adp "$RESTORE_NAME" >&2 || true
    echo "Timed out waiting for restore ${RESTORE_NAME}." >&2
    exit 1
  fi
  sleep 10
done

echo "Applying DR-specific S3 role and environment values." >&2
oc annotate sa/s3-writer sa/dashboard -n dr-demo \
  eks.amazonaws.com/role-arn="$APP_S3_ROLE_ARN_DR" \
  --overwrite >&2

oc set env deployment/telemetry-transmitter deployment/mission-control -n dr-demo \
  S3_BUCKET="$APP_BUCKET_DR" \
  AWS_REGION="$DR_REGION" \
  CLUSTER_NAME="$DR_CLUSTER_NAME" \
  AWS_ROLE_ARN="$APP_S3_ROLE_ARN_DR" >&2

echo "DR workload restore and configuration completed." >&2
