#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: deploy-phoenix.sh

Deploys the Phoenix Mission Control application via Helm on the primary cluster.
Clones the chart repo if not already present, installs with IRSA and EFS values,
and waits for all workloads to be ready.

Run while logged in to the primary cluster.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 1 ;;
  esac
done

: "${PRIMARY_CLUSTER_NAME:?}"
: "${PRIMARY_REGION:?}"
: "${DR_REGION:?}"
: "${DR_CLUSTER_NAME:?}"
: "${APP_BUCKET_PRIMARY:?}"
: "${APP_S3_ROLE_ARN_PRIMARY:?}"
: "${PRIMARY_EFS:?}"
: "${AWS_ACCOUNT_ID:?}"

NAMESPACE="dr-demo"

oc whoami >/dev/null

if [ ! -d "phoenix-mission-control" ]; then
  echo "Cloning phoenix-mission-control chart..." >&2
  git clone https://github.com/rh-mobb/phoenix-mission-control.git >&2
fi

echo "Installing Phoenix Mission Control on ${PRIMARY_CLUSTER_NAME}..." >&2

helm upgrade --install phoenix-mission-control ./phoenix-mission-control/chart \
  --namespace "$NAMESPACE" --create-namespace \
  --set region="$PRIMARY_REGION" \
  --set clusterName="$PRIMARY_CLUSTER_NAME" \
  --set s3.bucket="$APP_BUCKET_PRIMARY" \
  --set s3.roleArn="arn:aws:iam::${AWS_ACCOUNT_ID}:role/${PRIMARY_CLUSTER_NAME}-dr-demo-s3" \
  --set efs.fileSystemId="$PRIMARY_EFS" \
  --set primaryRegion="$PRIMARY_REGION" \
  --set primaryCluster="$PRIMARY_CLUSTER_NAME" \
  --set drRegion="$DR_REGION" \
  --set drCluster="$DR_CLUSTER_NAME" >&2

echo "Waiting for workloads to be ready..." >&2
oc rollout status deployment/mission-control -n "$NAMESPACE" --timeout=600s >&2
oc rollout status deployment/telemetry-transmitter -n "$NAMESPACE" --timeout=600s >&2
oc rollout status statefulset/flight-recorder -n "$NAMESPACE" --timeout=600s >&2

oc wait pvc/shared-flight-data -n "$NAMESPACE" --for=jsonpath='{.status.phase}'=Bound --timeout=300s >&2
oc wait pvc/flight-data-flight-recorder-0 -n "$NAMESPACE" --for=jsonpath='{.status.phase}'=Bound --timeout=300s >&2
oc wait pvc/flight-data-flight-recorder-1 -n "$NAMESPACE" --for=jsonpath='{.status.phase}'=Bound --timeout=300s >&2

oc get deploy,sts,svc,route,pvc -n "$NAMESPACE" >&2

echo "Phoenix Mission Control deployed to $NAMESPACE on $PRIMARY_CLUSTER_NAME." >&2
