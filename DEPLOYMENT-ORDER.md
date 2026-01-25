# FIAP Tech Challenge - Deployment Order

## Overview

This document describes the **correct deployment and destruction order** for all infrastructure components, including the 2-phase EKS deployment.

## 🚀 Deployment Order (deploy-all.yml)

```
┌─────────────────────────────────────────────────────────────────┐
│ 0. Validate Prerequisites                                      │
│    - Check AWS credentials                                     │
│    - Verify S3 backend exists                                  │
└─────────────────────────────────────────────────────────────────┘
                             ↓
┌─────────────────────────────────────────────────────────────────┐
│ 1a. Deploy EKS Cluster (Phase 1)                               │
│     Repository: kubernetes-core-infra                           │
│     Creates: VPC, Subnets, NAT Gateway, EKS Cluster, Nodes     │
│     Duration: ~40-50 minutes                                    │
└─────────────────────────────────────────────────────────────────┘
                             ↓
┌─────────────────────────────────────────────────────────────────┐
│ 1b. Deploy K8s Addons (Phase 2)                                │
│     Repository: kubernetes-addons                               │
│     Creates: Namespaces, AWS LB Controller, Metrics Server     │
│     Reads: Cluster info from Phase 1 via remote_state          │
│     Duration: ~3-10 minutes                                     │
└─────────────────────────────────────────────────────────────────┘
                             ↓
┌─────────────────────────────────────────────────────────────────┐
│ 2. Deploy Database                                             │
│    Repository: database-managed-infra                           │
│    Creates: RDS PostgreSQL, Secrets Manager                    │
│    Duration: ~10-15 minutes                                     │
└─────────────────────────────────────────────────────────────────┘
                             ↓
┌─────────────────────────────────────────────────────────────────┐
│ 3. Deploy Lambda Functions                                     │
│    Repository: lambda-api-handler                               │
│    Creates: Lambda functions, API Gateway                       │
│    Duration: ~5-8 minutes                                       │
└─────────────────────────────────────────────────────────────────┘
                             ↓
┌─────────────────────────────────────────────────────────────────┐
│ 4. Deploy K8s Application                                      │
│    Repository: k8s-main-service                                 │
│    Creates: Application pods, services, ingress                │
│    Duration: ~5-10 minutes                                      │
└─────────────────────────────────────────────────────────────────┘
```

**Total Time:** ~63-93 minutes

## 🔥 Destruction Order (destroy-all.yml)

**IMPORTANT:** Destroy in **REVERSE ORDER** to avoid dependency issues.

```
┌─────────────────────────────────────────────────────────────────┐
│ 1. Destroy K8s Application                                     │
│    Repository: k8s-main-service                                 │
│    Deletes: Application pods, services, ingress                │
└─────────────────────────────────────────────────────────────────┘
                             ↓
┌─────────────────────────────────────────────────────────────────┐
│ 2. Destroy Lambda Functions                                    │
│    Repository: lambda-api-handler                               │
│    Deletes: Lambda functions, API Gateway                       │
└─────────────────────────────────────────────────────────────────┘
                             ↓
┌─────────────────────────────────────────────────────────────────┐
│ 3. Destroy Database                                            │
│    Repository: database-managed-infra                           │
│    Deletes: RDS instance (no final snapshot), Secrets          │
└─────────────────────────────────────────────────────────────────┘
                             ↓
┌─────────────────────────────────────────────────────────────────┐
│ 4a. Destroy K8s Addons (Phase 2)                               │
│     Repository: kubernetes-addons                               │
│     Deletes: Helm releases, namespaces (Terraform state)       │
│     Duration: ~3-5 minutes                                      │
└─────────────────────────────────────────────────────────────────┘
                             ↓
┌─────────────────────────────────────────────────────────────────┐
│ 4b. Destroy EKS Cluster (Phase 1)                              │
│     Repository: kubernetes-core-infra                           │
│     Deletes: EKS cluster, nodes, VPC, subnets, NAT Gateway     │
│     Duration: ~15-20 minutes                                    │
└─────────────────────────────────────────────────────────────────┘
```

**Total Time:** ~23-33 minutes

## 🔧 Manual Cleanup (if needed)

If Terraform destroy fails or leaves orphaned resources:

```bash
cd infra-orchestrator
./scripts/cleanup-aws-resources.sh staging
```

This script:
- ✅ Forcefully deletes ALL AWS resources
- ✅ Cleans up VPCs aggressively (ENIs, NAT Gateways, etc.)
- ⚠️ **DESTRUCTIVE** - requires typing "DELETE" to confirm
- 🎯 kubernetes-addons resources are auto-deleted when cluster is deleted

## 📋 Terraform State Keys

| Repository | State Key |
|------------|-----------|
| kubernetes-core-infra | `kubernetes-core-infra/terraform.tfstate` |
| **kubernetes-addons** | **`kubernetes-addons/terraform.tfstate`** |
| database-managed-infra | `database-managed-infra/terraform.tfstate` |
| lambda-api-handler | `lambda-api-handler/terraform.tfstate` |
| k8s-main-service | N/A (Kustomize) |

## 🔍 Why 2 Phases for EKS?

**Problem:** Terraform providers (kubernetes, helm) initialize **BEFORE** `terraform plan/apply`. If they're in the same state as EKS cluster creation, they fail with:
```
Error: Kubernetes cluster unreachable: connection refused
```

**Solution:** Split into 2 states:
1. **Phase 1** (kubernetes-core-infra): Creates cluster → Saves endpoint to S3
2. **Phase 2** (kubernetes-addons): Reads endpoint from S3 → Initializes K8s/Helm providers → Creates resources

This is the **official HashiCorp pattern** for EKS + Terraform.

## 🚨 Common Issues

### Issue: "K8s addons destroy failed"
**Cause:** EKS cluster already deleted (addons destroyed automatically)
**Fix:** Safe to ignore - addons are deleted when cluster is deleted

### Issue: "VPC still exists after destroy"
**Cause:** Orphaned ENIs, NAT Gateways, or security group rules
**Fix:** Run cleanup script:
```bash
./scripts/cleanup-aws-resources.sh staging
```

### Issue: "Terraform state lock"
**Cause:** Previous workflow interrupted
**Fix:** Clean locks manually:
```bash
aws dynamodb scan --table-name fiap-terraform-locks
aws dynamodb delete-item --table-name fiap-terraform-locks --key '{"LockID": {"S": "..."}}
```

## 📊 Resource Dependencies

```
VPC (Phase 1)
 ├─ EKS Cluster (Phase 1)
 │   └─ K8s Namespaces (Phase 2)
 │       ├─ Helm Releases (Phase 2)
 │       └─ Application Pods (k8s-main-service)
 ├─ RDS Database (database-managed-infra)
 └─ Lambda Functions (lambda-api-handler)
```

## 🎯 Quick Commands

```bash
# Full deployment
cd infra-orchestrator
gh workflow run deploy-all.yml --field environment=staging

# Full destruction
gh workflow run destroy-all.yml --field environment=staging --field confirm=DESTROY

# Manual Phase 2 deployment (after Phase 1 exists)
cd kubernetes-addons/terraform
terraform init -backend-config="bucket=fiap-tech-challenge-tf-state-$(aws sts get-caller-identity --query Account --output text)"
terraform apply -var="environment=staging"

# Manual Phase 2 destruction (before Phase 1 destroyed)
cd kubernetes-addons/terraform
terraform destroy -var="environment=staging"
```
