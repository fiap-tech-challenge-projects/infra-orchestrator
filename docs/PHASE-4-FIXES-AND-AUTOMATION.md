# Phase 4 Deployment Fixes and Automation

## Executive Summary

This document captures all the issues encountered during Phase 4 deployment and their solutions. It also provides automation scripts to prevent these issues in future deployments.

**Date**: 2026-02-11
**Status**: In Progress

---

## Issues Encountered and Solutions

### 1. Database Tables Not Created

**Problem**: Prisma migrations were never run on the RDS database, causing "table does not exist" errors.

**Root Cause**:
- No migration files exist in `/prisma/migrations/` directory
- Migrations not executed during deployment

**Solution**:
- Created Kubernetes Job to run `prisma db push` in cluster
- Job installs Prisma CLI temporarily in `/tmp` to avoid production image bloat
- File: `/Users/finha/code/personal/fiap/os-service/k8s/migration-job.yaml`

**Automation**:
- Add init container to deployments that runs migrations before app starts
- OR: Run migration job as part of CI/CD pipeline before deployment

### 2. IRSA (IAM Roles for Service Accounts) Not Configured

**Problem**: Service accounts had IRSA role annotations but:
- Role ARNs had placeholder "ACCOUNT_ID" instead of real account ID
- IAM roles didn't exist
- Pods couldn't publish events to EventBridge or consume from SQS

**Error Message**:
```
InvalidIdentityToken: No OpenIDConnect provider found in your account
```

**Root Cause**:
- AWS Academy environment has limited IAM permissions
- OIDC provider exists but IAM roles were never created
- Service accounts referenced non-existent roles

**Solution**:
- Removed IRSA annotations from service accounts
- Created K8s secrets with AWS credentials (access key, secret key, session token)
- Patched deployments to inject AWS credentials as environment variables

**Files Modified**:
- Removed annotation: `kubectl annotate serviceaccount os-service -n ftc-app eks.amazonaws.com/role-arn-`
- Created secrets: `os-service-aws-creds`, `billing-service-aws-creds`
- Patched: os-service deployment, billing-service deployment

**Limitation**: AWS Academy session tokens expire every 4 hours. Need to refresh credentials periodically.

**Proper Solution** (for production):
1. Create IAM roles for each service with trust policy for OIDC provider:
```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {
      "Federated": "arn:aws:iam::305032652600:oidc-provider/oidc.eks.us-east-1.amazonaws.com/id/04BCD543DFE4A4D8E63C3B78198B4076"
    },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": {
        "oidc.eks.us-east-1.amazonaws.com/id/04BCD543DFE4A4D8E63C3B78198B4076:sub": "system:serviceaccount:ftc-app:os-service"
      }
    }
  }]
}
```
2. Attach policies for EventBridge PutEvents and SQS SendMessage/ReceiveMessage
3. Update service account annotations with real role ARNs

### 3. Dependency Injection Errors in Use Cases

**Problem**: Use cases couldn't resolve dependencies, causing "Nest can't resolve dependencies" errors.

**Error Example**:
```
Nest can't resolve dependencies of the CreateBudgetUseCase (?, Object)
```

**Root Cause**:
- NestJS modules provided dependencies using string tokens ('IBudgetRepository', 'IEventPublisher')
- Use case constructors didn't have `@Inject` decorators to specify which token to inject

**Files Fixed** (14 files total):

**Billing Service** (9 files):
- `src/application/budgets/use-cases/create-budget.use-case.ts`
- `src/application/budgets/use-cases/approve-budget.use-case.ts`
- `src/application/budgets/use-cases/reject-budget.use-case.ts`
- `src/application/budgets/use-cases/get-budget.use-case.ts`
- `src/application/budgets/use-cases/list-budgets.use-case.ts`
- `src/application/payments/use-cases/create-payment.use-case.ts`
- `src/application/payments/use-cases/process-webhook.use-case.ts`
- `src/application/payments/use-cases/get-payment.use-case.ts`
- `src/application/payments/use-cases/get-payment-qr-code.use-case.ts`

**Execution Service** (5 files):
- `src/application/executions/use-cases/create-execution.use-case.ts`
- `src/application/executions/use-cases/add-task.use-case.ts`
- `src/application/executions/use-cases/start-execution.use-case.ts`
- `src/application/executions/use-cases/complete-execution.use-case.ts`
- `src/application/executions/use-cases/get-execution.use-case.ts`

**Solution Pattern**:
```typescript
// BEFORE (wrong)
constructor(
  private readonly budgetRepository: IBudgetRepository,
  private readonly eventPublisher: IEventPublisher,
) {}

// AFTER (correct)
import { Inject } from '@nestjs/common'

constructor(
  @Inject('IBudgetRepository')
  private readonly budgetRepository: IBudgetRepository,
  @Inject('IEventPublisher')
  private readonly eventPublisher: IEventPublisher,
) {}
```

### 4. Mongoose Schema Type Inference Error

**Problem**: Mongoose couldn't determine types for enum fields in execution-service.

**Error**:
```
CannotDetermineTypeError: Cannot determine a type for the "ExecutionTaskDocument.status" field
```

**Root Cause**: Mongoose requires explicit `type: String` for enum properties in schemas.

**File Fixed**: `execution-service/src/infra/database/schemas/execution.schema.ts`

**Solution**:
```typescript
// BEFORE (wrong)
@Prop({ required: true, enum: TaskStatus })
status: TaskStatus

// AFTER (correct)
@Prop({ required: true, type: String, enum: TaskStatus })
status: TaskStatus
```

### 5. Docker Architecture Mismatch

**Problem**: Pods failed to start with "exec format error".

**Error**:
```
exec /usr/bin/dumb-init: exec format error
```

**Root Cause**: Docker images built on M1 Mac (arm64) but EKS nodes are amd64.

**Solution**: Added `--platform linux/amd64` to all docker build commands in `orchestration/build-and-push-images.sh`.

**Before**:
```bash
docker build -t os-service:latest .
```

**After**:
```bash
docker build --platform linux/amd64 -t os-service:latest .
```

### 6. ALB Ingress SSL Certificate Error

**Problem**: Ingress failed to create ALB due to missing SSL certificate.

**Error**:
```
Failed deploy model due to ValidationError: A certificate must be specified for HTTPS listeners
```

**Root Cause**: Ingress had SSL redirect annotation but no certificate configured.

**Solution**: Removed SSL redirect and configured HTTP-only:
```bash
kubectl annotate ingress -n ftc-app os-service \
  alb.ingress.kubernetes.io/ssl-redirect- \
  alb.ingress.kubernetes.io/listen-ports='[{"HTTP": 80}]' \
  --overwrite
```

### 7. K8s Image Names Missing ECR Repository

**Problem**: Pods in ImagePullBackOff with "InvalidImageName" error.

**Root Cause**: Kustomization files had placeholder "ACCOUNT_ID" or local image names instead of full ECR URIs.

**Files Fixed**:
- `os-service/k8s/overlays/development/kustomization.yaml`
- `billing-service/k8s/overlays/development/kustomization.yaml`
- `execution-service/k8s/overlays/development/kustomization.yaml`

**Solution**: Updated image names to full ECR URIs:
```yaml
images:
  - name: os-service
    newName: 305032652600.dkr.ecr.us-east-1.amazonaws.com/os-service
    newTag: latest
```

### 8. NestJS 11 Dependency Compatibility

**Problem**: Docker builds failed with dependency conflicts.

**Root Cause**:
- `@nestjs/config` 3.x incompatible with NestJS 11 (requires 4.x)
- `reflect-metadata` 0.1.13 incompatible with NestJS 11 (requires 0.2.x)
- ESLint 9.x incompatible with @typescript-eslint 8.x

**Files Fixed**:
- All three services' `package.json` files

**Solution**:
```json
{
  "@nestjs/config": "^4.0.0",
  "reflect-metadata": "^0.2.2",
  "eslint": "^8.57.0"
}
```

### 9. Prisma CLI Version Mismatch

**Problem**: `npx prisma generate` in Dockerfile installed Prisma 7 instead of Prisma 6 from package.json.

**Root Cause**: npx always fetches latest version from npm, ignoring package.json.

**Solution**: Use npm script instead:
```dockerfile
# BEFORE
RUN npx prisma generate

# AFTER
RUN npm run prisma:generate
```

### 10. SQS Message Consumption Not Working

**Problem**: Messages published to EventBridge → SQS but billing-service not consuming them.

**Current Status**: ONGOING INVESTIGATION

**Observations**:
- 1 message in `billing-service-events-development` queue
- Billing service logs show no consumer activity
- Might need AWS credentials (similar to EventBridge publishing issue)

**Next Steps**:
- Verify SQS consumer is configured in billing-service
- Check if consumer needs AWS credentials
- Verify SQS permissions

### 11. Execution Service CrashLoopBackOff

**Problem**: Execution service pod continuously restarting.

**Root Cause**: MongoDB URI not configured but execution-service expects MongoDB connection.

**Current Status**: ONGOING

**Solution Options**:
1. Deploy MongoDB/DocumentDB in AWS
2. Use DynamoDB as primary database instead of MongoDB
3. Make MongoDB connection optional for testing

---

## Automation Plan

### Phase 1: Database Migration Automation

**Goal**: Run migrations automatically before app starts, every deployment.

**Approach**: Use Kubernetes Init Containers

**Files to Create**:
1. Update each service's deployment to add init container:

```yaml
initContainers:
  - name: migration
    image: <same-as-main-image>
    command: ["/bin/sh", "-c"]
    args:
      - |
        export HOME=/tmp
        export NPM_CONFIG_CACHE=/tmp/.npm
        cd /tmp
        npm install --no-save prisma@^6.0.0
        cd /app
        /tmp/node_modules/.bin/prisma db push --accept-data-loss || \
        /tmp/node_modules/.bin/prisma migrate deploy
    envFrom:
      - secretRef:
          name: os-service-secrets
```

**Alternative**: Pre-deployment migration job in CI/CD:
```yaml
# .github/workflows/deploy.yml
- name: Run Database Migrations
  run: |
    kubectl run migration-temp --image=$ECR_IMAGE \
      --restart=Never --rm -i --quiet \
      --env-from=secret/os-service-secrets \
      -- sh -c "cd /app && npx prisma migrate deploy"
```

### Phase 2: AWS Credentials Automation

**Goal**: Automatically inject AWS credentials into all services that need them.

**Approach 1** (Quick - for AWS Academy):
- Script to sync AWS credentials from local machine to K8s secrets
- Run before each deployment
- Add to `orchestration/update-aws-credentials.sh`:

```bash
#!/bin/bash
set -e

SERVICES=("os-service" "billing-service" "execution-service")
NAMESPACE="ftc-app"

ACCESS_KEY=$(aws configure get aws_access_key_id)
SECRET_KEY=$(aws configure get aws_secret_access_key)
SESSION_TOKEN=$(aws configure get aws_session_token)

for SERVICE in "${SERVICES[@]}"; do
  echo "Updating AWS credentials for ${SERVICE}..."

  kubectl create secret generic ${SERVICE}-aws-creds -n ${NAMESPACE} \
    --from-literal=AWS_ACCESS_KEY_ID="${ACCESS_KEY}" \
    --from-literal=AWS_SECRET_ACCESS_KEY="${SECRET_KEY}" \
    --from-literal=AWS_SESSION_TOKEN="${SESSION_TOKEN}" \
    --from-literal=AWS_REGION="us-east-1" \
    --dry-run=client -o yaml | kubectl apply -f -

  # Restart deployment to pick up new credentials
  kubectl rollout restart deployment/${SERVICE} -n ${NAMESPACE}
done

echo "✅ AWS credentials updated for all services"
```

**Approach 2** (Proper - for production):
- Create IAM roles with proper trust policies for OIDC
- Add Terraform module for service IAM roles
- Update service accounts with correct role ARNs

**File to Create**: `orchestration/terraform/irsa-roles.tf`

```hcl
# IAM Role for OS Service
module "os_service_irsa" {
  source = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"

  role_name = "os-service-role"

  role_policy_arns = {
    eventbridge = aws_iam_policy.eventbridge_publish.arn
    sqs = aws_iam_policy.sqs_consume.arn
  }

  oidc_providers = {
    main = {
      provider_arn = data.aws_eks_cluster.main.identity[0].oidc[0].issuer
      namespace_service_accounts = ["ftc-app:os-service"]
    }
  }
}

# EventBridge Publish Policy
resource "aws_iam_policy" "eventbridge_publish" {
  name = "EventBridgePublishPolicy"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "events:PutEvents"
      ]
      Resource = aws_cloudwatch_event_bus.main.arn
    }]
  })
}

# SQS Consume Policy
resource "aws_iam_policy" "sqs_consume" {
  name = "SQSConsumePolicy"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "sqs:ReceiveMessage",
        "sqs:DeleteMessage",
        "sqs:GetQueueAttributes"
      ]
      Resource = "arn:aws:sqs:us-east-1:305032652600:*-service-events-*"
    }]
  })
}
```

### Phase 3: Complete Deployment Script

**Goal**: One command to deploy everything with all fixes applied.

**File**: `orchestration/deploy-phase-4.sh`

```bash
#!/bin/bash
set -e

echo "🚀 Phase 4 Complete Deployment Script"
echo "======================================"

# Configuration
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REGION="us-east-1"
ECR_URL="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"
NAMESPACE="ftc-app"

# Step 1: Update AWS Credentials
echo ""
echo "📋 Step 1: Updating AWS Credentials..."
./update-aws-credentials.sh

# Step 2: Build and Push Docker Images
echo ""
echo "🐳 Step 2: Building and Pushing Docker Images..."
./build-and-push-images.sh

# Step 3: Run Database Migrations
echo ""
echo "🗄️ Step 3: Running Database Migrations..."

# OS Service Migration
kubectl run os-migration-temp --image=${ECR_URL}/os-service:latest \
  --restart=Never --rm -i --quiet \
  --env-from=secret/os-service-secrets \
  -- sh -c "
    export HOME=/tmp NPM_CONFIG_CACHE=/tmp/.npm
    cd /tmp && npm install --no-save prisma@^6.0.0
    cd /app && /tmp/node_modules/.bin/prisma db push --accept-data-loss
  " && echo "✅ OS Service migrations complete"

# Billing Service Migration (if using DB)
# Similar for other services...

# Step 4: Deploy Services
echo ""
echo "☸️ Step 4: Deploying Services to Kubernetes..."
kubectl apply -k ../os-service/k8s/overlays/development
kubectl apply -k ../billing-service/k8s/overlays/development
kubectl apply -k ../execution-service/k8s/overlays/development

# Step 5: Wait for Deployments
echo ""
echo "⏳ Step 5: Waiting for Deployments..."
kubectl rollout status deployment/os-service -n ${NAMESPACE} --timeout=5m
kubectl rollout status deployment/dev-billing-service -n ${NAMESPACE} --timeout=5m
# Skip execution-service if MongoDB not configured

# Step 6: Verify Health
echo ""
echo "🏥 Step 6: Verifying Health..."
ALB_URL=$(kubectl get ingress os-service -n ${NAMESPACE} -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')

if [ -z "$ALB_URL" ]; then
  echo "❌ ALB URL not found. Waiting for ingress..."
  sleep 30
  ALB_URL=$(kubectl get ingress os-service -n ${NAMESPACE} -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
fi

echo "ALB URL: http://${ALB_URL}/api/v1"

# Wait for ALB to be ready
echo "Waiting for ALB to be ready..."
for i in {1..30}; do
  if curl -s -f "http://${ALB_URL}/api/v1/health" > /dev/null 2>&1; then
    echo "✅ Health check passed!"
    break
  fi
  echo "Attempt $i/30..."
  sleep 10
done

# Step 7: Show Status
echo ""
echo "📊 Deployment Status:"
kubectl get pods -n ${NAMESPACE}
echo ""
echo "🌐 API Endpoints:"
echo "   Health: http://${ALB_URL}/api/v1/health"
echo "   Swagger: http://${ALB_URL}/api/v1/docs"
echo ""
echo "✅ Deployment Complete!"
```

### Phase 4: CI/CD Pipeline Updates

**Goal**: GitHub Actions workflow that applies all fixes automatically.

**File**: `.github/workflows/deploy-phase-4.yml`

```yaml
name: Deploy Phase 4 Services

on:
  push:
    branches: [main, develop]
  workflow_dispatch:

env:
  AWS_REGION: us-east-1
  ACCOUNT_ID: 305032652600
  ECR_URL: 305032652600.dkr.ecr.us-east-1.amazonaws.com

jobs:
  deploy:
    runs-on: ubuntu-latest

    steps:
      - uses: actions/checkout@v4

      - name: Configure AWS Credentials
        uses: aws-actions/configure-aws-credentials@v4
        with:
          aws-access-key-id: ${{ secrets.AWS_ACCESS_KEY_ID }}
          aws-secret-access-key: ${{ secrets.AWS_SECRET_ACCESS_KEY }}
          aws-session-token: ${{ secrets.AWS_SESSION_TOKEN }}
          aws-region: ${{ env.AWS_REGION }}

      - name: Configure kubectl
        run: |
          aws eks update-kubeconfig --name fiap-tech-challenge-eks-development --region ${{ env.AWS_REGION }}

      - name: Build and Push OS Service
        run: |
          cd os-service
          docker build --platform linux/amd64 -t ${{ env.ECR_URL }}/os-service:${{ github.sha }} .
          docker push ${{ env.ECR_URL }}/os-service:${{ github.sha }}
          docker tag ${{ env.ECR_URL }}/os-service:${{ github.sha }} ${{ env.ECR_URL }}/os-service:latest
          docker push ${{ env.ECR_URL }}/os-service:latest

      - name: Run OS Service Migrations
        run: |
          kubectl run os-migration-${{ github.run_number }} \
            --image=${{ env.ECR_URL }}/os-service:latest \
            --restart=Never --rm -i --quiet \
            --env-from=secret/os-service-secrets \
            -- sh -c "
              export HOME=/tmp NPM_CONFIG_CACHE=/tmp/.npm
              cd /tmp && npm install --no-save prisma@^6.0.0
              cd /app && /tmp/node_modules/.bin/prisma db push --accept-data-loss
            "

      - name: Deploy OS Service
        run: |
          cd os-service
          kubectl apply -k k8s/overlays/development
          kubectl rollout status deployment/os-service -n ftc-app --timeout=5m

      # Repeat for billing-service and execution-service...

      - name: Verify Deployment
        run: |
          kubectl get pods -n ftc-app
          ALB_URL=$(kubectl get ingress os-service -n ftc-app -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
          curl -f http://${ALB_URL}/api/v1/health
```

---

## Testing Automation

### E2E Test Script (Already Created)

File: `orchestration/test-e2e-flow.sh`

**Usage**:
```bash
cd orchestration
chmod +x test-e2e-flow.sh
./test-e2e-flow.sh
```

**What it tests**:
1. Create client
2. Register vehicle
3. Create service order (triggers OrderCreated event)
4. Wait for budget generation
5. Get budget
6. Approve budget
7. Create payment
8. Simulate payment completion
9. Wait for execution creation
10. Get execution
11. Start execution
12. Complete execution
13. Verify final state

---

## Quick Reference

### Deploy Everything (Development)
```bash
cd orchestration
./deploy-phase-4.sh
```

### Update AWS Credentials Only
```bash
cd orchestration
./update-aws-credentials.sh
```

### Run Migrations Only
```bash
kubectl apply -f ../os-service/k8s/migration-job.yaml
kubectl logs -n ftc-app job/os-service-migration --follow
```

### Rebuild and Redeploy Single Service
```bash
cd os-service
docker build --platform linux/amd64 -t 305032652600.dkr.ecr.us-east-1.amazonaws.com/os-service:latest .
docker push 305032652600.dkr.ecr.us-east-1.amazonaws.com/os-service:latest
kubectl rollout restart deployment/os-service -n ftc-app
```

### Check Deployment Status
```bash
kubectl get pods -n ftc-app
kubectl get ingress -n ftc-app
kubectl logs -n ftc-app -l app=os-service --tail=50
```

### Test E2E Flow
```bash
cd orchestration
./test-e2e-flow.sh
```

---

## Remaining Work

### High Priority
1. ✅ Fix database migrations (DONE)
2. ✅ Fix IRSA/AWS credentials (DONE)
3. ✅ Fix dependency injection errors (DONE)
4. ✅ Fix Docker architecture mismatch (DONE)
5. ⏳ Fix SQS message consumption (IN PROGRESS)
6. ⏳ Fix execution-service MongoDB connection (IN PROGRESS)

### Medium Priority
7. ⏳ Create `update-aws-credentials.sh` script
8. ⏳ Create `deploy-phase-4.sh` complete deployment script
9. ⏳ Update CI/CD workflows
10. ⏳ Add init containers for automatic migrations

### Low Priority
11. Create proper IAM roles for IRSA (production solution)
12. Set up MongoDB/DocumentDB for execution-service
13. Configure SSL certificate for HTTPS
14. Add monitoring and alerting

---

## Lessons Learned

1. **Check Phase 3**: Always review previous phase implementations first to avoid re-solving problems
2. **Automation First**: Manual fixes should immediately be turned into automated scripts
3. **AWS Academy Limitations**: Be aware of IAM restrictions and session token expiration
4. **Test Early**: Run E2E tests as soon as basic deployment is working
5. **Document Everything**: Keep a running log of all issues and solutions
6. **Init Containers**: Use them for one-time setup tasks like migrations
7. **Platform Consistency**: Always specify `--platform linux/amd64` when building on Apple Silicon

---

## Next Steps

1. Complete the automation scripts (update-aws-credentials.sh, deploy-phase-4.sh)
2. Fix SQS message consumption in billing-service
3. Test complete E2E flow
4. Update all services with init containers for migrations
5. Create comprehensive deployment guide for colleagues
6. Set up CI/CD pipeline with all fixes integrated

