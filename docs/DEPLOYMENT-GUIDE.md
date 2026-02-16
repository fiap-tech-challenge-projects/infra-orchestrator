# Phase 4 - Complete Deployment Guide

**For someone who knows nothing about this project**

This guide contains EVERYTHING you need to deploy and test the Phase 4 microservices architecture from scratch.

---

## Table of Contents

1. [What is This Project?](#what-is-this-project)
2. [Prerequisites](#prerequisites)
3. [Quick Start (Automated)](#quick-start-automated)
4. [Manual Deployment Steps](#manual-deployment-steps)
5. [Testing](#testing)
6. [Troubleshooting](#troubleshooting)
7. [CI/CD Pipeline](#cicd-pipeline)
8. [Cleanup](#cleanup)

---

## What is This Project?

FIAP Tech Challenge is a **mechanical workshop management system** built with:
- ☁️ **Cloud**: AWS (EKS, RDS, DynamoDB, EventBridge, SQS)
- 🏗️ **Architecture**: Microservices + Event-Driven
- 📦 **Container Orchestration**: Kubernetes

**3 Microservices:**
1. **OS Service** - Manages clients, vehicles, service orders (PostgreSQL)
2. **Billing Service** - Handles budgets and payments (DynamoDB)
3. **Execution Service** - Tracks service execution (MongoDB)

**Event Flow Example:**
```
Create Order → EventBridge → SQS → Billing creates Budget → ... → Execution tracks work
```

**Architecture:**
```
User → ALB (Ingress) → Kubernetes Pods → EventBridge/SQS → RDS/DynamoDB
```

---

## Prerequisites

### Required Tools

```bash
# 1. AWS CLI
brew install awscli
aws --version  # Should be 2.x

# 2. kubectl
brew install kubectl
kubectl version --client

# 3. Docker
# Download from https://www.docker.com/products/docker-desktop
docker --version

# 4. Terraform (optional, infrastructure already deployed)
brew install terraform
terraform --version

# 5. jq (for JSON parsing in scripts)
brew install jq
```

### AWS Account Setup

**If using AWS Academy:**
1. Go to AWS Academy → Start Lab
2. Click "AWS Details" → "Show" credentials
3. Copy the credentials

**Configure AWS CLI:**
```bash
aws configure
# Enter:
#   AWS Access Key ID: <from AWS Academy>
#   AWS Secret Access Key: <from AWS Academy>
#   Default region: us-east-1
#   Default output format: json

# If using AWS Academy, also set session token:
aws configure set aws_session_token <SESSION_TOKEN>
```

**Verify:**
```bash
aws sts get-caller-identity
# Should show your account ID: 305032652600
```

### Configure kubectl

```bash
# Update kubeconfig for EKS cluster
aws eks update-kubeconfig --name fiap-tech-challenge-eks-development --region us-east-1

# Verify
kubectl get nodes
# Should show 2 nodes in Ready state
```

---

## Quick Start (Automated)

**Deploy everything with one command:**

```bash
cd orchestration

# This script does EVERYTHING:
# - Updates AWS credentials
# - Creates ECR repositories
# - Builds Docker images (multi-platform)
# - Runs database migrations
# - Deploys all services
# - Verifies health
./deploy-phase-4.sh
```

**That's it!** Wait ~10 minutes for everything to deploy.

**Get your API URL:**
```bash
kubectl get ingress os-service -n ftc-app -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
```

**Test it:**
```bash
ALB_URL=$(kubectl get ingress os-service -n ftc-app -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
curl http://${ALB_URL}/api/v1/health
```

---

## Manual Deployment Steps

If you want to understand what happens or need to deploy step-by-step:

### Step 1: Update AWS Credentials

**Why:** Services need AWS credentials to publish events to EventBridge and consume from SQS.

```bash
cd orchestration
./update-aws-credentials.sh
```

**What this does:**
- Syncs your local AWS credentials to Kubernetes secrets
- Removes invalid IRSA annotations
- Patches all deployments
- Restarts pods

### Step 2: Create ECR Repositories

```bash
./create-ecr-repos.sh
```

Creates 3 ECR repositories:
- `os-service`
- `billing-service`
- `execution-service`

### Step 3: Build and Push Docker Images

```bash
./build-and-push-images.sh
```

**Important:** Uses `--platform linux/amd64` (required for EKS, even on M1 Mac).

### Step 4: Run Database Migrations

```bash
kubectl apply -f ../os-service/k8s/migration-job.yaml
kubectl logs -n ftc-app job/os-service-migration --follow
```

**What this does:**
- Installs Prisma CLI in /tmp
- Runs `prisma db push` to create tables in RDS
- Completes before deployment

### Step 5: Deploy Services

```bash
# Deploy OS Service
kubectl apply -k ../os-service/k8s/overlays/development

# Deploy Billing Service
kubectl apply -k ../billing-service/k8s/overlays/development

# Deploy Execution Service (optional - needs MongoDB)
kubectl apply -k ../execution-service/k8s/overlays/development
```

### Step 6: Wait for Readiness

```bash
kubectl get pods -n ftc-app --watch
# Wait until all pods show 2/2 Running
```

**Check status:**
```bash
kubectl get pods -n ftc-app
kubectl get svc -n ftc-app
kubectl get ingress -n ftc-app
```

### Step 7: Get ALB URL

```bash
ALB_URL=$(kubectl get ingress os-service -n ftc-app -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
echo "API Base: http://${ALB_URL}/api/v1"
```

**Wait for ALB:** May take 2-3 minutes after ingress creation.

---

## Testing

### Health Check

```bash
ALB_URL=$(kubectl get ingress os-service -n ftc-app -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
curl http://${ALB_URL}/api/v1/health
```

**Expected:**
```json
{
  "status": "healthy",
  "timestamp": "2026-02-11T20:00:00.000Z",
  "service": "os-service",
  "database": "connected"
}
```

### Automated E2E Tests

```bash
cd orchestration
./test-e2e-flow.sh
```

**Tests:**
1. ✅ Create Client
2. ✅ Register Vehicle
3. ✅ Create Service Order
4. ✅ Verify EventBridge publishing
5. ✅ Get Budget (from billing service)
6. ✅ Approve Budget
7. ✅ Create Payment
8. ✅ Complete Execution

### Manual API Testing

**1. Create Client:**
```bash
curl -X POST http://${ALB_URL}/api/v1/clients \
  -H "Content-Type: application/json" \
  -d '{
    "name": "Test Client",
    "email": "test@example.com",
    "cpfCnpj": "11144477735",
    "phone": "11999999999"
  }'
```

**2. Register Vehicle:**
```bash
curl -X POST http://${ALB_URL}/api/v1/vehicles \
  -H "Content-Type: application/json" \
  -d '{
    "licensePlate": "ABC-1234",
    "make": "Toyota",
    "model": "Corolla",
    "year": 2020,
    "clientId": "<CLIENT_ID>"
  }'
```

**3. Create Service Order:**
```bash
curl -X POST http://${ALB_URL}/api/v1/service-orders \
  -H "Content-Type: application/json" \
  -d '{
    "clientId": "<CLIENT_ID>",
    "vehicleId": "<VEHICLE_ID>",
    "notes": "Oil change and tire rotation"
  }'
```

---

## Troubleshooting

### Problem: "Table does not exist" error

**Symptom:** 500 error when creating resources

**Solution:**
```bash
# Run migrations
kubectl apply -f ../os-service/k8s/migration-job.yaml
kubectl logs -n ftc-app job/os-service-migration --follow

# Restart deployment
kubectl rollout restart deployment/os-service -n ftc-app
```

### Problem: "InvalidIdentityToken" in logs

**Symptom:** Services can't publish to EventBridge

**Solution:**
```bash
# AWS Academy credentials expired (every 4 hours)
cd orchestration
./update-aws-credentials.sh
```

### Problem: ImagePullBackOff

**Symptom:** Pods stuck, can't pull images

**Solution:**
```bash
# Rebuild and push images
cd orchestration
./build-and-push-images.sh

# Verify images in ECR
aws ecr describe-images --repository-name os-service
```

### Problem: ALB not responding

**Symptom:** curl timeout on ALB URL

**Check ingress:**
```bash
kubectl describe ingress os-service -n ftc-app
```

**Check pod health:**
```bash
kubectl get pods -n ftc-app
kubectl logs -n ftc-app -l app=os-service --tail=50
```

**Common issues:**
- ALB still provisioning (wait 3-5 minutes)
- Pods not healthy (check logs)
- Security groups blocking traffic (check AWS Console)

### Problem: Pods CrashLoopBackOff

**Check logs:**
```bash
kubectl logs -n ftc-app <pod-name> --previous
```

**Common causes:**
- Missing environment variables
- Database connection failed
- Application error

### Check All Logs

```bash
# OS Service
kubectl logs -n ftc-app -l app=os-service -f

# Billing Service
kubectl logs -n ftc-app -l app=billing-service -f

# All pods
kubectl get pods -n ftc-app
kubectl describe pod <pod-name> -n ftc-app
```

---

## CI/CD Pipeline

### GitHub Actions Workflow

**File:** `.github/workflows/deploy-phase-4.yml`

**Triggers:**
- Push to `main` or `develop` branch
- Manual workflow dispatch

**Steps:**
1. Configure AWS credentials
2. Update kubectl config
3. Build Docker images (all 3 services)
4. Push to ECR
5. Run database migrations
6. Deploy to Kubernetes
7. Verify health endpoints

### Manual CI/CD Trigger

```bash
# Via GitHub UI:
# 1. Go to Actions tab
# 2. Select "Deploy Phase 4" workflow
# 3. Click "Run workflow"
# 4. Select branch
# 5. Click "Run workflow"

# Via gh CLI:
gh workflow run deploy-phase-4.yml
```

### Secrets Required

Set these in GitHub repo settings → Secrets:

```
AWS_ACCESS_KEY_ID
AWS_SECRET_ACCESS_KEY
AWS_SESSION_TOKEN (if using AWS Academy)
AWS_ACCOUNT_ID (305032652600)
```

---

## Cleanup

### Delete Everything

```bash
cd orchestration

# Delete Kubernetes resources
kubectl delete namespace ftc-app

# Delete ECR images
aws ecr delete-repository --repository-name os-service --force
aws ecr delete-repository --repository-name billing-service --force
aws ecr delete-repository --repository-name execution-service --force

# Destroy infrastructure (if needed)
cd ../kubernetes-addons/terraform
terraform destroy -auto-approve

cd ../../kubernetes-core-infra/terraform
terraform destroy -auto-approve
```

**Or use the cleanup script:**
```bash
cd orchestration
./cleanup-all.sh
```

---

## Quick Reference

### Essential Commands

```bash
# Get API URL
ALB_URL=$(kubectl get ingress os-service -n ftc-app -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
echo "http://${ALB_URL}/api/v1"

# Check pods
kubectl get pods -n ftc-app

# Check logs
kubectl logs -n ftc-app -l app=os-service -f

# Restart service
kubectl rollout restart deployment/os-service -n ftc-app

# Refresh AWS credentials (every 4 hours for AWS Academy)
cd orchestration && ./update-aws-credentials.sh

# Run E2E tests
cd orchestration && ./test-e2e-flow.sh
```

### URLs

**API Base:**
```
http://<ALB_URL>/api/v1
```

**Endpoints:**
- Health: `/health`
- Swagger: `/docs`
- Clients: `/clients`
- Vehicles: `/vehicles`
- Service Orders: `/service-orders`
- Budgets: `/budgets`
- Payments: `/payments`

---

## Architecture Details

### Services

| Service | Tech Stack | Database | Port |
|---------|------------|----------|------|
| OS Service | NestJS 11, Prisma 6, PostgreSQL | RDS | 3000 |
| Billing Service | NestJS 11, DynamoDB | DynamoDB | 3001 |
| Execution Service | NestJS 11, Mongoose | MongoDB | 3002 |

### AWS Resources

| Resource | Name | Purpose |
|----------|------|---------|
| EKS Cluster | fiap-tech-challenge-eks-development | Container orchestration |
| RDS PostgreSQL | fiap-tech-challenge-development-postgres | OS Service data |
| DynamoDB Tables | 6 tables (budgets, payments, executions) | Billing & Execution data |
| EventBridge | fiap-tech-challenge-event-bus-development | Event publishing |
| SQS Queues | 6 queues (3 services x 2 queues each) | Event consumption |
| ALB | Auto-generated | HTTP ingress |
| ECR | 3 repositories | Docker images |

### Event Flow

```
1. Create Order (OS Service)
   ↓
2. Publish OrderCreated event (EventBridge)
   ↓
3. Route to SQS queue (billing-service-events)
   ↓
4. Billing Service consumes event
   ↓
5. Create Budget automatically
   ↓
6. Approve Budget
   ↓
7. Publish BudgetApproved event
   ↓
8. Payment flow starts...
```

---

## Support

**Issues:**
- Check logs: `kubectl logs -n ftc-app -l app=<service>`
- Review this guide's Troubleshooting section
- Check AWS Console for resource status

**Related Docs:**
- `CLAUDE.md` - Project overview in root
- `README.md` - Quick links in root
- `PHASE-4-FIXES-AND-AUTOMATION.md` - Detailed issues/solutions (this folder)

**Scripts Location:**
```
orchestration/
├── deploy-phase-4.sh          # Complete deployment
├── update-aws-credentials.sh  # Refresh credentials
├── build-and-push-images.sh   # Build images
├── test-e2e-flow.sh           # Run tests
└── cleanup-all.sh             # Delete everything
```

---

**Last Updated:** 2026-02-11
**Status:** ✅ Production Ready
**Tested:** ✅ Full E2E Flow Verified

