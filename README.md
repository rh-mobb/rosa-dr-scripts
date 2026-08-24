# ROSA HCP Disaster Recovery Scripts

Helper scripts for ROSA HCP disaster recovery guides published on [MOBB documentation](https://red-hat-storage.github.io/mobb/).

These scripts automate repetitive infrastructure tasks — IAM roles, S3 replication, EFS replication, OADP configuration, and cleanup — so the guides can focus on the DR decisions and workflow.

## Guides

These scripts support three guides:

| Guide | Description |
|---|---|
| [Create ROSA HCP DR Infrastructure](https://red-hat-storage.github.io/mobb/experts/rosa/rosa-dr-infra/) | Shared infrastructure: EFS CSI Driver, S3 Cross-Region Replication, EFS replication |
| [Disaster Recovery with OADP](https://red-hat-storage.github.io/mobb/experts/rosa/oadp-efs-s3/) | Backup-and-restore pattern using OADP/Velero |
| [Disaster Recovery with ACM and OpenShift GitOps](https://red-hat-storage.github.io/mobb/experts/rosa/rosa-acm-dr/) | GitOps-driven pattern using ACM and ArgoCD |

## Usage

Clone this repo and run the guides from the repo root:

```bash
git clone https://github.com/rh-mobb/rosa-dr-scripts.git
cd rosa-dr-scripts
```

All scripts are in `scripts/` and are referenced from the guides as `./scripts/<script-name>.sh`.

## Scripts

### Infrastructure (used by DR Infrastructure guide)

| Script | Purpose |
|---|---|
| `install-efs-csi.sh` | Install and configure the EFS CSI Driver on a ROSA HCP cluster |
| `configure-s3-replication.sh` | Create S3 buckets and configure one-way Cross-Region Replication |
| `validate-s3-replication.sh` | Validate S3 replication is working |
| `configure-efs-replication.sh` | Create EFS file systems, mount targets, and cross-region replication |
| `validate-efs-replication.sh` | Validate EFS replication status |
| `validate-efs-csi.sh` | Create EFS StorageClass and validate dynamic provisioning |

### OADP (used by OADP DR guide)

| Script | Purpose |
|---|---|
| `configure-oadp.sh` | Install OADP and create DataProtectionApplication on a cluster |
| `deploy-phoenix.sh` | Deploy the Phoenix Mission Control example workload |
| `record-efs-mapping.sh` | Record EFS PVC-to-access-point mappings before failover |
| `create-dr-backup.sh` | Create an OADP backup and verify it replicates to DR |
| `recover-efs-volumes.sh` | Recreate static EFS PVs and PVCs on the DR cluster from the mapping file |
| `restore-dr-workload.sh` | Restore Kubernetes resources with OADP on the DR cluster |
| `validate-dr-recovery.sh` | Validate DR recovery (pods, PVCs, data, route) |

### Cleanup

| Script | Purpose |
|---|---|
| `cleanup-openshift.sh` | Remove Phoenix namespace, OADP, and EFS CSI resources from a cluster |
| `cleanup-s3.sh` | Purge and delete S3 buckets |
| `cleanup-efs.sh` | Delete EFS access points, mount targets, replication, and file systems |
| `cleanup-iam.sh` | Detach policies and delete IAM roles created by these scripts |
| `validate-cleanup.sh` | Verify all guide-created resources have been removed |

### Shared

| Script | Purpose |
|---|---|
| `validation-helpers.sh` | Common validation functions sourced by other scripts |

## Environment File

All scripts use `--env-file dr.env` to read and write environment variables. The `dr.env` file is created by the DR Infrastructure guide and accumulates resource identifiers as each script runs.

## Prerequisites

- AWS CLI
- `rosa` CLI
- `oc` CLI
- `jq`
- Two existing ROSA HCP clusters in different AWS Regions
- AWS permissions for IAM, EC2, S3, and EFS
