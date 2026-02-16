# FIAP Tech Challenge - Infrastructure Orchestrator

Central orchestration hub for deploying all FIAP Tech Challenge Phase 4 infrastructure. Supports two deployment paths: **local scripts** (for development) and **GitHub Actions workflows** (for CI/CD).

## Quick Start

### Local Deployment (from your machine)

```bash
# Deploy everything
./scripts/deploy-all.sh --env=development

# Deploy only services (infra already exists)
./scripts/deploy-services.sh --env=development

# Destroy everything
./scripts/destroy-all.sh --env=development --force
```

### GitHub Actions Deployment

1. Go to **Actions** > **Bootstrap AWS Infrastructure** > Run workflow (`create`)
2. Go to **Actions** > **Deploy All Infrastructure** > Select environment > Run workflow
3. To tear down: **Actions** > **Destroy All Infrastructure** > Select environment > Type `DESTROY`

## Deployment Order

Infrastructure must be deployed in this order (dependencies):

```
1a. kubernetes-core-infra  ->  VPC, EKS Cluster (Phase 1)
1b. kubernetes-addons      ->  Namespaces, Helm releases (Phase 2)
2.  database-managed-infra ->  RDS PostgreSQL, DynamoDB, DocumentDB
2.5 messaging-infra        ->  EventBridge, SQS queues
3.  lambda-api-handler     ->  Lambda Auth, API Gateway
4.  Microservices          ->  ECR repos, Docker images, DB migrations,
                               os-service, billing-service, execution-service
```

## Scripts Reference

### Deployment Scripts

| Script | Description |
|--------|-------------|
| `deploy-all.sh` | Full deployment: infra + ECR + Docker + migrations + services |
| `deploy-services.sh` | Deploy/update microservices only (assumes infra exists) |
| `build-and-push.sh` | Build Docker images and push to ECR |
| `create-ecr-repos.sh` | Create ECR repositories for all microservices |

### Cleanup Scripts

| Script | Description |
|--------|-------------|
| `destroy-all.sh` | Full teardown: services + Terraform + AWS CLI cleanup |
| `cleanup-aws-resources.sh` | Aggressive AWS resource cleanup (catches orphans) |

### Credential Management

| Script | Description |
|--------|-------------|
| `update-k8s-credentials.sh` | Sync AWS credentials to K8s secrets (for EventBridge/SQS) |
| `update-github-secrets.sh` | Bulk update AWS secrets across all 11 GitHub repos |
| `update-gh-pat.sh` | Update GH_PAT secret across repos |
| `delete-session-token.sh` | Remove AWS_SESSION_TOKEN from GitHub repos |

### Testing Scripts

| Script | Description |
|--------|-------------|
| `test-e2e.sh` | Full E2E flow: Order -> Budget -> Payment -> Execution |
| `test-saga-rollback.sh` | Saga compensation: Budget rejection prevents execution |

## Workflows Reference

### bootstrap.yml

Creates/destroys Terraform backend resources (S3 bucket + DynamoDB lock table).

**Usage**: Actions > Bootstrap AWS Infrastructure > `create` or `destroy`

### deploy-all.yml

Orchestrated deployment of all infrastructure in correct order with skip options:
- `skip_eks`, `skip_database`, `skip_messaging`, `skip_lambda`, `skip_app`

Includes Phase 4 microservices: ECR repos, Docker builds, DB migrations, K8s deployments.

**Usage**: Actions > Deploy All Infrastructure > Select environment (development/production)

### destroy-all.yml

Destroys all infrastructure in reverse order. Requires typing `DESTROY` to confirm.

**Usage**: Actions > Destroy All Infrastructure > Select environment > Type `DESTROY`

## Environment Strategy

| Branch | Environment | Terraform Workspace |
|--------|-------------|-------------------|
| `develop` | development | development |
| `main` | production | production |

All infra repos accept `development` and `production` via `workflow_dispatch`.

## Required GitHub Secrets

| Secret | Description | Required In |
|--------|-------------|-------------|
| `AWS_ACCESS_KEY_ID` | AWS access key | All repos |
| `AWS_SECRET_ACCESS_KEY` | AWS secret key | All repos |
| `AWS_SESSION_TOKEN` | AWS session (Academy) | All repos |
| `GH_PAT` | GitHub PAT with `repo` + `workflow` | infra-orchestrator |

### Bulk Update Secrets

```bash
./scripts/update-github-secrets.sh
```

Supports pasting AWS Academy credential blocks. Auto-detects GitHub username. Updates all 11 repos.

## AWS Academy Notes

- `AWS_SESSION_TOKEN` expires every 4 hours
- Uses `LabRole` (cannot create custom IAM roles)
- Single NAT Gateway for cost optimization
- Re-run `./scripts/update-k8s-credentials.sh` after token refresh

## Estimated Costs

| Resource | Monthly Cost |
|----------|-------------|
| EKS Cluster | ~$73 |
| EC2 (2x t3.medium) | ~$60 |
| RDS (db.t3.micro) | ~$15 |
| NAT Gateway | ~$32 |
| Lambda | ~$0 (free tier) |
| **Total** | **~$180/month** |

Use `destroy-all.sh` or `Destroy All` workflow when not in use.

## Troubleshooting

### Bad credentials / Resource not accessible

The `GH_PAT` may be expired or missing permissions. Regenerate with `repo` + `workflow` scopes.

### Timeout on EKS/RDS

EKS takes ~15-20 min, RDS ~10-15 min. This is normal.

### Session token expired

```bash
# Update local K8s secrets
./scripts/update-k8s-credentials.sh

# Update GitHub secrets for CI/CD
./scripts/update-github-secrets.sh
```
