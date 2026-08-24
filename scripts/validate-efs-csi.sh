#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: validate-efs-csi.sh --efs-id FILE_SYSTEM_ID [--smoke-test]

Creates or updates the EFS StorageClass on the currently logged-in cluster.
With --smoke-test, also creates a throwaway PVC to verify dynamic provisioning.
EOF
}

EFS_ID=""
SMOKE_TEST=false

while [ $# -gt 0 ]; do
  case "$1" in
    --efs-id) EFS_ID="$2"; shift 2 ;;
    --smoke-test) SMOKE_TEST=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 1 ;;
  esac
done

[ -n "$EFS_ID" ] || { echo "--efs-id is required" >&2; exit 1; }

oc whoami >/dev/null

echo "Applying EFS StorageClass with fileSystemId=$EFS_ID..." >&2
cat <<EOF | oc apply -f - >&2
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: efs-sc
parameters:
  basePath: /dynamic_provisioning
  directoryPerms: "755"
  fileSystemId: ${EFS_ID}
  gidRangeEnd: "2000"
  gidRangeStart: "1000"
  provisioningMode: efs-ap
provisioner: efs.csi.aws.com
reclaimPolicy: Delete
volumeBindingMode: Immediate
EOF

oc get storageclass efs-sc >&2

if [ "$SMOKE_TEST" = "true" ]; then
  echo "Running dynamic PVC smoke test..." >&2
  oc create namespace efs-smoke --dry-run=client -o yaml | oc apply -f - >&2
  cat <<'EOF' | oc apply -n efs-smoke -f - >&2
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: efs-smoke
spec:
  accessModes: ["ReadWriteMany"]
  storageClassName: efs-sc
  resources:
    requests:
      storage: 1Gi
EOF

  oc wait pvc/efs-smoke -n efs-smoke --for=jsonpath='{.status.phase}'=Bound --timeout=300s >&2
  oc get pvc -n efs-smoke -o custom-columns=NAME:.metadata.name,STATUS:.status.phase,PV:.spec.volumeName >&2
  oc delete namespace efs-smoke --wait=true >&2
  echo "Smoke test passed." >&2
fi

echo "EFS CSI StorageClass configured." >&2
