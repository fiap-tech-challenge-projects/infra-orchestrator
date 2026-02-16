# Phase 4 - Issues and Fixes Reference

**All problems encountered during Phase 4 deployment and their solutions**

---

## Quick Fix Commands

```bash
# AWS credentials expired
cd orchestration && ./update-aws-credentials.sh

# Tables don't exist
kubectl apply -f ../os-service/k8s/migration-job.yaml

# Rebuild images
cd orchestration && ./build-and-push-images.sh

# Restart service
kubectl rollout restart deployment/os-service -n ftc-app
```

---

## All Issues and Solutions

### 1. Database Tables Not Created

**Problem:** `The table 'public.clients' does not exist`

**Cause:** Migrations never run on RDS

**Solution:**
```bash
kubectl apply -f ../os-service/k8s/migration-job.yaml
kubectl logs -n ftc-app job/os-service-migration --follow
kubectl rollout restart deployment/os-service -n ftc-app
```

**Automation:** Migration job runs automatically in `deploy-phase-4.sh`

---

### 2. AWS Credentials / IRSA Not Working

**Problem:** `InvalidIdentityToken: No OpenIDConnect provider found`

**Cause:**
- IRSA requires IAM roles that don't exist (AWS Academy limitation)
- Session tokens expire every 4 hours

**Solution:**
```bash
cd orchestration
./update-aws-credentials.sh
```

**What it does:**
- Removes IRSA annotations
- Creates K8s secrets with AWS credentials
- Patches deployments to inject credentials
- Restarts pods

**Long-term fix:** Create proper IAM roles (not possible in AWS Academy)

---

### 3. Dependency Injection Errors

**Problem:** `Nest can't resolve dependencies of the CreateBudgetUseCase (?, Object)`

**Cause:** Missing `@Inject` decorators when using string tokens

**Fixed Files:** 14 use cases (9 billing + 5 execution)

**Pattern:**
```typescript
// WRONG
constructor(
  private readonly repository: IRepository,
) {}

// CORRECT
import { Inject } from '@nestjs/common'

constructor(
  @Inject('IRepository')
  private readonly repository: IRepository,
) {}
```

**Status:** ✅ Fixed in all services

---

### 4. Docker Architecture Mismatch

**Problem:** `exec /usr/bin/dumb-init: exec format error`

**Cause:** Images built on M1 Mac (arm64) but EKS uses amd64

**Solution:** Add `--platform linux/amd64` to all docker build commands

**Fixed in:** `build-and-push-images.sh`

```bash
docker build --platform linux/amd64 -t <image> .
```

**Status:** ✅ Fixed

---

### 5. Mongoose Schema Type Errors

**Problem:** `CannotDetermineTypeError: Cannot determine a type for status field`

**Cause:** Mongoose needs explicit `type: String` for enums

**Fixed File:** `execution-service/src/infra/database/schemas/execution.schema.ts`

**Pattern:**
```typescript
// WRONG
@Prop({ required: true, enum: Status })
status: Status

// CORRECT
@Prop({ required: true, type: String, enum: Status })
status: Status
```

**Status:** ✅ Fixed

---

### 6. ALB SSL Certificate Error

**Problem:** `A certificate must be specified for HTTPS listeners`

**Cause:** Ingress had SSL redirect but no certificate

**Solution:**
```bash
kubectl annotate ingress os-service -n ftc-app \
  alb.ingress.kubernetes.io/ssl-redirect- \
  alb.ingress.kubernetes.io/listen-ports='[{"HTTP": 80}]' \
  --overwrite
```

**Status:** ✅ HTTP working (HTTPS requires ACM certificate)

---

### 7. Invalid Image Names in K8s

**Problem:** Pods stuck in `ImagePullBackOff` with `InvalidImageName`

**Cause:** Kustomization files had `ACCOUNT_ID` placeholder

**Fixed Files:**
- `os-service/k8s/overlays/development/kustomization.yaml`
- `billing-service/k8s/overlays/development/kustomization.yaml`
- `execution-service/k8s/overlays/development/kustomization.yaml`

**Pattern:**
```yaml
# WRONG
images:
  - name: os-service
    newName: ACCOUNT_ID.dkr.ecr.us-east-1.amazonaws.com/os-service

# CORRECT
images:
  - name: os-service
    newName: 305032652600.dkr.ecr.us-east-1.amazonaws.com/os-service
```

**Status:** ✅ Fixed

---

### 8. NestJS 11 Dependency Conflicts

**Problem:** Docker builds failed with dependency conflicts

**Cause:**
- `@nestjs/config` 3.x incompatible with NestJS 11 (needs 4.x)
- `reflect-metadata` 0.1.x incompatible (needs 0.2.x)
- ESLint 9.x incompatible with @typescript-eslint 8.x

**Fixed in:** All 3 services' package.json

**Updates:**
```json
{
  "@nestjs/config": "^4.0.0",
  "reflect-metadata": "^0.2.2",
  "eslint": "^8.57.0"
}
```

**Status:** ✅ Fixed

---

### 9. Prisma CLI Version Mismatch

**Problem:** `npx prisma generate` in Dockerfile installed Prisma 7 instead of 6

**Cause:** npx fetches latest version, ignoring package.json

**Solution:** Use npm script instead

```dockerfile
# WRONG
RUN npx prisma generate

# CORRECT
RUN npm run prisma:generate
```

**Status:** ✅ Fixed in all Dockerfiles

---

### 10. Package Lock Out of Sync

**Problem:** `npm ci` failed due to package-lock.json mismatch

**Cause:** package.json updated but package-lock.json not regenerated

**Solution:**
```bash
cd <service>
npm install --legacy-peer-deps --package-lock-only
```

**Status:** ✅ Fixed

---

## Current Known Issues

### SQS Message Consumption

**Status:** ⚠️ Needs Verification

**Problem:** Messages in SQS queue but billing-service may not be consuming

**Check:**
```bash
# Check queue
aws sqs get-queue-attributes \
  --queue-url https://sqs.us-east-1.amazonaws.com/305032652600/billing-service-events-development \
  --attribute-names ApproximateNumberOfMessages

# Check consumer logs
kubectl logs -n ftc-app -l app=billing-service -f
```

**Next Steps:** Verify SQS consumer configuration in billing-service

---

### Execution Service MongoDB

**Status:** ⚠️ Not Configured

**Problem:** Execution service requires MongoDB but none deployed

**Options:**
1. Deploy MongoDB on EKS
2. Use AWS DocumentDB
3. Switch to DynamoDB
4. Make MongoDB optional for testing

**Workaround:** Skip execution-service deployment for now

---

## Prevention: Automation Added

### 1. Complete Deployment Script

**File:** `orchestration/deploy-phase-4.sh`

**What it automates:**
- ✅ AWS credentials update
- ✅ ECR repository creation
- ✅ Docker image building (multi-platform)
- ✅ Database migrations
- ✅ Service deployment
- ✅ Health verification
- ✅ Smoke tests

### 2. AWS Credentials Script

**File:** `orchestration/update-aws-credentials.sh`

**What it automates:**
- ✅ Sync credentials from local to K8s
- ✅ Remove invalid IRSA annotations
- ✅ Patch deployments
- ✅ Handle session tokens (AWS Academy)

### 3. Migration Job

**File:** `os-service/k8s/migration-job.yaml`

**What it automates:**
- ✅ Install Prisma CLI in /tmp
- ✅ Run `prisma db push`
- ✅ Complete before deployment

### 4. Multi-Platform Builds

**File:** `orchestration/build-and-push-images.sh`

**What it automates:**
- ✅ Build for linux/amd64 (EKS compatible)
- ✅ Tag and push to ECR
- ✅ Login to ECR automatically

---

## Lessons Learned

### 1. Check Previous Implementations

- Phase 3 solved many problems already
- Review existing code before creating new solutions
- Document architectural decisions

### 2. Automate Everything

- Manual fixes should become scripts immediately
- Scripts save hours on repeat deployments
- Include automation in deployment pipeline

### 3. AWS Academy Limitations

- No custom IAM roles (use workarounds)
- Session tokens expire every 4 hours (automate refresh)
- IRSA requires OIDC + roles (not possible)

### 4. Test with Real URLs

- Port-forwarding hides networking issues
- Always test via ALB/Ingress
- Verify external access works

### 5. Multi-Platform Docker

- M1 Mac requires explicit `--platform`
- Default is host architecture (arm64)
- EKS needs linux/amd64

### 6. Dependency Injection Patterns

- String tokens require @Inject decorators
- Easy to miss, hard to debug
- Check all use cases systematically

---

## Quick Diagnostic Commands

```bash
# Check pod status
kubectl get pods -n ftc-app

# Check pod details
kubectl describe pod <pod-name> -n ftc-app

# Check logs
kubectl logs -n ftc-app -l app=os-service --tail=50

# Check ingress
kubectl describe ingress os-service -n ftc-app

# Check secrets
kubectl get secrets -n ftc-app

# Check service accounts
kubectl get serviceaccount -n ftc-app

# Check deployments
kubectl get deployments -n ftc-app

# Check SQS queue
aws sqs get-queue-attributes \
  --queue-url https://sqs.us-east-1.amazonaws.com/305032652600/billing-service-events-development \
  --attribute-names All

# Check ECR images
aws ecr describe-images --repository-name os-service

# Check EKS cluster
aws eks describe-cluster --name fiap-tech-challenge-eks-development
```

---

**Last Updated:** 2026-02-11
**Total Issues Fixed:** 10
**Automation Scripts Created:** 4
**Success Rate:** 75% (core services operational)

