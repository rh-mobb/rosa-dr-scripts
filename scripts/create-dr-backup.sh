#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: create-dr-backup.sh [--sync-to-dr-for-validation]

Waits for the OADP Backup named by BACKUP_NAME to complete, lists the backup
objects in the primary OADP bucket, and waits for the exact backup prefix to
replicate to the DR OADP bucket through S3 CRR.

Run while logged in to the primary cluster.

Use --sync-to-dr-for-validation only for deterministic validation runs where
you intentionally do not want to wait for S3 CRR timing.
EOF
}

SYNC_TO_DR_FOR_VALIDATION=false

while [ $# -gt 0 ]; do
  case "$1" in
    --sync-to-dr-for-validation) SYNC_TO_DR_FOR_VALIDATION=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 1 ;;
  esac
done

: "${BACKUP_NAME:?}"
: "${PRIMARY_REGION:?}"
: "${DR_REGION:?}"
: "${OADP_BUCKET_PRIMARY:?}"
: "${OADP_BUCKET_DR:?}"

export AWS_PAGER=""

oc whoami >/dev/null

echo "Waiting for OADP Backup ${BACKUP_NAME} to complete." >&2

for attempt in $(seq 1 60); do
  phase=$(oc get backup -n openshift-adp "$BACKUP_NAME" -o jsonpath='{.status.phase}' 2>/dev/null || true)
  phase=${phase:-Pending}
  printf '[%s] backup/%s phase=%s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$BACKUP_NAME" "$phase" >&2
  case "$phase" in
    Completed) break ;;
    Failed|PartiallyFailed)
      oc describe backup -n openshift-adp "$BACKUP_NAME" >&2 || true
      exit 1
      ;;
  esac
  if [ "$attempt" -eq 60 ]; then
    oc describe backup -n openshift-adp "$BACKUP_NAME" >&2 || true
    echo "Timed out waiting for backup ${BACKUP_NAME}." >&2
    exit 1
  fi
  sleep 10
done

aws s3 ls "s3://${OADP_BUCKET_PRIMARY}/velero/backups/${BACKUP_NAME}/" --region "$PRIMARY_REGION" >&2

if [ "$SYNC_TO_DR_FOR_VALIDATION" = "true" ]; then
  echo "Validation-only: copying exact backup prefix to DR object bucket." >&2
  aws s3 sync "s3://${OADP_BUCKET_PRIMARY}/velero/backups/${BACKUP_NAME}/" \
    "s3://${OADP_BUCKET_DR}/velero/backups/${BACKUP_NAME}/" \
    --source-region "$PRIMARY_REGION" \
    --region "$DR_REGION" >&2
else
  echo "Waiting for backup prefix to replicate to DR object bucket." >&2
  for attempt in $(seq 1 90); do
    listing=$(aws s3 ls "s3://${OADP_BUCKET_DR}/velero/backups/${BACKUP_NAME}/" --region "$DR_REGION" 2>/dev/null || true)
    if [ -n "$listing" ]; then
      printf '%s\n' "$listing" >&2
      break
    fi
    printf '[%s] waiting for S3 CRR of backup prefix %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$BACKUP_NAME" >&2
    if [ "$attempt" -eq 90 ]; then
      echo "Timed out waiting for backup prefix ${BACKUP_NAME} to replicate to DR bucket." >&2
      exit 1
    fi
    sleep 20
  done
fi

echo "Backup ${BACKUP_NAME} completed and replicated to DR bucket." >&2
