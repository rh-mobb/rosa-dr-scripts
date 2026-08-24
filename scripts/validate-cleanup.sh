#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: validate-cleanup.sh

Verifies cleanup removed guide-created S3 buckets, EFS file systems, EFS helper
security groups, IAM roles/policies, and OpenShift validation resources.
Prints PASS / STILL EXISTS lines and returns nonzero if anything remains.

For OpenShift resource checks, run while logged in to each cluster in turn,
or skip those checks by setting SKIP_OPENSHIFT=true.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 1 ;;
  esac
done

: "${PRIMARY_CLUSTER_NAME:?}"
: "${DR_CLUSTER_NAME:?}"
: "${PRIMARY_REGION:?}"
: "${DR_REGION:?}"
: "${APP_BUCKET_PRIMARY:?}"
: "${APP_BUCKET_DR:?}"
: "${OADP_BUCKET_PRIMARY:?}"
: "${OADP_BUCKET_DR:?}"
: "${PRIMARY_EFS:?}"
: "${DR_EFS:?}"
: "${EFS_SG_PRIMARY:?}"
: "${EFS_SG_DR:?}"
: "${APP_S3_ROLE_NAME_PRIMARY:?}"
: "${APP_S3_ROLE_NAME_DR:?}"
: "${S3_REPLICATION_ROLE_NAME:?}"
: "${APP_S3_POLICY_ARN:?}"
: "${OADP_POLICY_ARN:?}"

export AWS_PAGER=""
failures=0

env_prefix() {
  printf '%s\n' "$1" | tr '[:lower:]-.' '[:upper:]__'
}

env_value() {
  local key="$1"
  printf '%s\n' "${!key:-}"
}

mark_absent() {
  local label="$1"
  local exists="$2"
  if [ "$exists" = "yes" ]; then
    echo "STILL EXISTS: $label"
    failures=$((failures + 1))
  else
    echo "PASS deleted: $label"
  fi
}

check_openshift_resource_absent() {
  local label="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    mark_absent "$label" yes
  else
    mark_absent "$label" no
  fi
}

for bucket in "$APP_BUCKET_PRIMARY" "$APP_BUCKET_DR" "$OADP_BUCKET_PRIMARY" "$OADP_BUCKET_DR"; do
  if aws s3api head-bucket --bucket "$bucket" >/dev/null 2>&1; then
    mark_absent "s3 bucket ${bucket}" yes
  else
    mark_absent "s3 bucket ${bucket}" no
  fi
done

for region_fs in "$PRIMARY_REGION:$PRIMARY_EFS" "$DR_REGION:$DR_EFS"; do
  region=${region_fs%%:*}
  fs=${region_fs##*:}
  if aws efs describe-file-systems --region "$region" --file-system-id "$fs" >/dev/null 2>&1; then
    mark_absent "efs file system ${fs}" yes
  else
    mark_absent "efs file system ${fs}" no
  fi
done

for region_sg in "$PRIMARY_REGION:$EFS_SG_PRIMARY" "$DR_REGION:$EFS_SG_DR"; do
  region=${region_sg%%:*}
  sg=${region_sg##*:}
  if aws ec2 describe-security-groups --region "$region" --group-ids "$sg" >/dev/null 2>&1; then
    mark_absent "efs security group ${sg}" yes
  else
    mark_absent "efs security group ${sg}" no
  fi
done

primary_prefix=$(env_prefix "$PRIMARY_CLUSTER_NAME")
dr_prefix=$(env_prefix "$DR_CLUSTER_NAME")
primary_efs_role_name=$(env_value "${primary_prefix}_EFS_CSI_ROLE_NAME")
dr_efs_role_name=$(env_value "${dr_prefix}_EFS_CSI_ROLE_NAME")
primary_efs_policy_arn=$(env_value "${primary_prefix}_EFS_CSI_POLICY_ARN")
dr_efs_policy_arn=$(env_value "${dr_prefix}_EFS_CSI_POLICY_ARN")

OADP_ROLE_ARN_PRIMARY="${OADP_ROLE_ARN_PRIMARY:-}"
OADP_ROLE_ARN_DR="${OADP_ROLE_ARN_DR:-}"

for role in \
  "$APP_S3_ROLE_NAME_PRIMARY" \
  "$APP_S3_ROLE_NAME_DR" \
  "$S3_REPLICATION_ROLE_NAME" \
  "${OADP_ROLE_ARN_PRIMARY:+${OADP_ROLE_ARN_PRIMARY##*/}}" \
  "${OADP_ROLE_ARN_DR:+${OADP_ROLE_ARN_DR##*/}}" \
  "${primary_efs_role_name:-}" \
  "${dr_efs_role_name:-}"
do
  [ -n "$role" ] || continue
  if aws iam get-role --role-name "$role" >/dev/null 2>&1; then
    mark_absent "iam role ${role}" yes
  else
    mark_absent "iam role ${role}" no
  fi
done

for policy in "$APP_S3_POLICY_ARN" "$OADP_POLICY_ARN" "$primary_efs_policy_arn" "$dr_efs_policy_arn"; do
  [ -n "$policy" ] || continue
  if aws iam get-policy --policy-arn "$policy" >/dev/null 2>&1; then
    mark_absent "iam policy ${policy}" yes
  else
    mark_absent "iam policy ${policy}" no
  fi
done

if [ "${SKIP_OPENSHIFT:-}" = "true" ]; then
  echo "Skipping OpenShift resource checks (SKIP_OPENSHIFT=true)."
else
  current_cluster=$(oc whoami --show-server 2>/dev/null || true)
  if [ -n "$current_cluster" ]; then
    echo "Checking OpenShift resources on current context (${current_cluster})."
    check_openshift_resource_absent "namespace/dr-demo" oc get namespace dr-demo
    check_openshift_resource_absent "namespace/efs-smoke" oc get namespace efs-smoke
    check_openshift_resource_absent "dpa/openshift-adp/dr-demo-dpa" oc get dpa dr-demo-dpa -n openshift-adp
    check_openshift_resource_absent "secret/openshift-adp/cloud-credentials" oc get secret cloud-credentials -n openshift-adp
    check_openshift_resource_absent "subscription/openshift-adp/redhat-oadp-operator" oc get subscription redhat-oadp-operator -n openshift-adp
    check_openshift_resource_absent "clustercsidriver/efs.csi.aws.com" oc get clustercsidriver efs.csi.aws.com
    check_openshift_resource_absent "secret/openshift-cluster-csi-drivers/aws-efs-cloud-credentials" oc get secret aws-efs-cloud-credentials -n openshift-cluster-csi-drivers
    check_openshift_resource_absent "subscription/openshift-cluster-csi-drivers/aws-efs-csi-driver-operator" oc get subscription aws-efs-csi-driver-operator -n openshift-cluster-csi-drivers
  else
    echo "Not logged in to any cluster. Skipping OpenShift resource checks."
  fi
fi

if [ "$failures" -gt 0 ]; then
  echo "Cleanup validation FAIL: ${failures} resource checks still exist." >&2
  exit 1
fi

echo "Cleanup validation PASS."
