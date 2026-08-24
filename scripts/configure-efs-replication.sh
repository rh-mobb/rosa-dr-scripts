#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: configure-efs-replication.sh

Requires PRIMARY_CLUSTER_NAME and DR_CLUSTER_NAME in the environment.
Detects regions, worker security groups, and subnets from the cluster names.

Creates or reuses named EFS security groups/file systems, creates missing mount
targets, and configures primary-to-DR EFS replication.
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

PRIMARY_REGION=$(rosa describe cluster -c "$PRIMARY_CLUSTER_NAME" -o json | jq -r '.region.id')
DR_REGION=$(rosa describe cluster -c "$DR_CLUSTER_NAME" -o json | jq -r '.region.id')

echo "Primary: $PRIMARY_CLUSTER_NAME ($PRIMARY_REGION)  DR: $DR_CLUSTER_NAME ($DR_REGION)" >&2

csv_to_words() {
  echo "$1" | tr ',' ' '
}

discover_subnets() {
  local cluster="$1"
  rosa list machinepools -c "$cluster" -o json \
    | jq -r '[.[].subnet? // empty] | flatten | unique | join(",")'
}

first_csv_value() {
  echo "$1" | awk -F, '{print $1}'
}

discover_worker_sg() {
  local cluster_name="$1"
  local region="$2"
  aws ec2 describe-instances \
    --region "$region" \
    --filters "Name=tag:api.openshift.com/name,Values=$cluster_name" \
              "Name=instance-state-name,Values=running" \
    --query 'Reservations[0].Instances[0].SecurityGroups[0].GroupId' \
    --output text 2>/dev/null || echo "None"
}

wait_efs_available() {
  local fs_id="$1"
  local region="$2"
  until [ "$(aws efs describe-file-systems \
    --file-system-id "$fs_id" \
    --region "$region" \
    --query 'FileSystems[0].LifeCycleState' \
    --output text)" = "available" ]; do
    echo "Waiting for EFS $fs_id in $region..." >&2
    sleep 10
  done
}

wait_mount_targets() {
  local fs_id="$1"
  local region="$2"
  until [ "$(aws efs describe-mount-targets \
    --file-system-id "$fs_id" \
    --region "$region" \
    --query 'length(MountTargets[?LifeCycleState!=`available`])' \
    --output text)" = "0" ]; do
    echo "Waiting for mount targets for $fs_id in $region..." >&2
    sleep 10
  done
}

find_security_group() {
  local name="$1"
  local vpc_id="$2"
  local region="$3"
  aws ec2 describe-security-groups \
    --region "$region" \
    --filters "Name=group-name,Values=${name}" "Name=vpc-id,Values=${vpc_id}" \
    --query 'SecurityGroups[0].GroupId' \
    --output text 2>/dev/null || true
}

ensure_security_group() {
  local name="$1"
  local vpc_id="$2"
  local region="$3"
  local sg_id
  sg_id=$(find_security_group "$name" "$vpc_id" "$region")
  if [ -n "$sg_id" ] && [ "$sg_id" != "None" ]; then
    echo "$sg_id"
    return
  fi
  aws ec2 create-security-group \
    --region "$region" \
    --group-name "$name" \
    --description "EFS access for ROSA DR" \
    --vpc-id "$vpc_id" \
    --query 'GroupId' --output text
}

allow_nfs_from_sg() {
  local efs_sg="$1"
  local worker_sg="$2"
  local region="$3"
  local output
  if output=$(aws ec2 authorize-security-group-ingress \
    --region "$region" \
    --group-id "$efs_sg" \
    --protocol tcp --port 2049 \
    --source-group "$worker_sg" 2>&1); then
    return
  fi
  if echo "$output" | grep -q "InvalidPermission.Duplicate"; then
    return
  fi
  echo "$output" >&2
  return 1
}

find_efs_by_name() {
  local name="$1"
  local region="$2"
  aws efs describe-file-systems \
    --region "$region" \
    --query "FileSystems[?Name=='${name}'].FileSystemId | [0]" \
    --output text 2>/dev/null || true
}

ensure_primary_efs() {
  local name="$1"
  local region="$2"
  local fs_id
  fs_id=$(find_efs_by_name "$name" "$region")
  if [ -n "$fs_id" ] && [ "$fs_id" != "None" ]; then
    echo "$fs_id"
    return
  fi
  aws efs create-file-system \
    --region "$region" \
    --encrypted \
    --tags "Key=Name,Value=${name}" \
    --query 'FileSystemId' --output text
}

ensure_mount_target() {
  local fs_id="$1"
  local subnet="$2"
  local sg_id="$3"
  local region="$4"
  local existing
  existing=$(aws efs describe-mount-targets \
    --file-system-id "$fs_id" \
    --region "$region" \
    --query "MountTargets[?SubnetId=='${subnet}'].MountTargetId | [0]" \
    --output text 2>/dev/null || true)
  if [ -n "$existing" ] && [ "$existing" != "None" ]; then
    return
  fi
  aws efs create-mount-target \
    --region "$region" \
    --file-system-id "$fs_id" \
    --subnet-id "$subnet" \
    --security-groups "$sg_id" >/dev/null
}

PRIMARY_SUBNET_IDS=$(discover_subnets "$PRIMARY_CLUSTER_NAME")
DR_SUBNET_IDS=$(discover_subnets "$DR_CLUSTER_NAME")

if [ -z "$PRIMARY_SUBNET_IDS" ]; then
  echo "Could not discover subnets for $PRIMARY_CLUSTER_NAME" >&2
  exit 1
fi
if [ -z "$DR_SUBNET_IDS" ]; then
  echo "Could not discover subnets for $DR_CLUSTER_NAME" >&2
  exit 1
fi

PRIMARY_WORKER_SECURITY_GROUP_ID=$(discover_worker_sg "$PRIMARY_CLUSTER_NAME" "$PRIMARY_REGION")
DR_WORKER_SECURITY_GROUP_ID=$(discover_worker_sg "$DR_CLUSTER_NAME" "$DR_REGION")

if [ "$PRIMARY_WORKER_SECURITY_GROUP_ID" = "None" ] || [ -z "$PRIMARY_WORKER_SECURITY_GROUP_ID" ]; then
  echo "Could not detect worker security group for $PRIMARY_CLUSTER_NAME. Ensure worker nodes are running." >&2
  exit 1
fi
if [ "$DR_WORKER_SECURITY_GROUP_ID" = "None" ] || [ -z "$DR_WORKER_SECURITY_GROUP_ID" ]; then
  echo "Could not detect worker security group for $DR_CLUSTER_NAME. Ensure worker nodes are running." >&2
  exit 1
fi

echo "Primary worker SG: $PRIMARY_WORKER_SECURITY_GROUP_ID  DR worker SG: $DR_WORKER_SECURITY_GROUP_ID" >&2

PRIMARY_SUBNET=$(first_csv_value "$PRIMARY_SUBNET_IDS")
DR_SUBNET=$(first_csv_value "$DR_SUBNET_IDS")

VPC_PRIMARY=$(aws ec2 describe-subnets \
  --subnet-ids "$PRIMARY_SUBNET" \
  --region "$PRIMARY_REGION" \
  --query 'Subnets[0].VpcId' --output text)

VPC_DR=$(aws ec2 describe-subnets \
  --subnet-ids "$DR_SUBNET" \
  --region "$DR_REGION" \
  --query 'Subnets[0].VpcId' --output text)

EFS_SG_PRIMARY=$(ensure_security_group "${PRIMARY_CLUSTER_NAME}-efs-dr-sg" "$VPC_PRIMARY" "$PRIMARY_REGION")
EFS_SG_DR=$(ensure_security_group "${DR_CLUSTER_NAME}-efs-dr-sg" "$VPC_DR" "$DR_REGION")

allow_nfs_from_sg "$EFS_SG_PRIMARY" "$PRIMARY_WORKER_SECURITY_GROUP_ID" "$PRIMARY_REGION"
allow_nfs_from_sg "$EFS_SG_DR" "$DR_WORKER_SECURITY_GROUP_ID" "$DR_REGION"

PRIMARY_EFS=$(ensure_primary_efs "${PRIMARY_CLUSTER_NAME}-dr-efs" "$PRIMARY_REGION")
wait_efs_available "$PRIMARY_EFS" "$PRIMARY_REGION"

for subnet in $(csv_to_words "$PRIMARY_SUBNET_IDS"); do
  ensure_mount_target "$PRIMARY_EFS" "$subnet" "$EFS_SG_PRIMARY" "$PRIMARY_REGION"
done
wait_mount_targets "$PRIMARY_EFS" "$PRIMARY_REGION"

DR_EFS=$(aws efs describe-replication-configurations \
  --region "$PRIMARY_REGION" \
  --file-system-id "$PRIMARY_EFS" \
  --query 'Replications[0].Destinations[0].FileSystemId' \
  --output text 2>/dev/null || true)

if [ -z "$DR_EFS" ] || [ "$DR_EFS" = "None" ]; then
  aws efs create-replication-configuration \
    --region "$PRIMARY_REGION" \
    --source-file-system-id "$PRIMARY_EFS" \
    --destinations "[{\"Region\":\"${DR_REGION}\"}]" >/dev/null

  DR_EFS=$(aws efs describe-replication-configurations \
    --region "$PRIMARY_REGION" \
    --file-system-id "$PRIMARY_EFS" \
    --query 'Replications[0].Destinations[0].FileSystemId' \
    --output text)
fi

wait_efs_available "$DR_EFS" "$DR_REGION"

for subnet in $(csv_to_words "$DR_SUBNET_IDS"); do
  ensure_mount_target "$DR_EFS" "$subnet" "$EFS_SG_DR" "$DR_REGION"
done
wait_mount_targets "$DR_EFS" "$DR_REGION"

echo "export PRIMARY_REGION=$PRIMARY_REGION"
echo "export DR_REGION=$DR_REGION"
echo "export PRIMARY_SUBNET_IDS=$PRIMARY_SUBNET_IDS"
echo "export DR_SUBNET_IDS=$DR_SUBNET_IDS"
echo "export PRIMARY_WORKER_SECURITY_GROUP_ID=$PRIMARY_WORKER_SECURITY_GROUP_ID"
echo "export DR_WORKER_SECURITY_GROUP_ID=$DR_WORKER_SECURITY_GROUP_ID"
echo "export VPC_PRIMARY=$VPC_PRIMARY"
echo "export VPC_DR=$VPC_DR"
echo "export EFS_SG_PRIMARY=$EFS_SG_PRIMARY"
echo "export EFS_SG_DR=$EFS_SG_DR"
echo "export PRIMARY_EFS=$PRIMARY_EFS"
echo "export DR_EFS=$DR_EFS"

echo "EFS replication configured: $PRIMARY_EFS -> $DR_EFS." >&2
