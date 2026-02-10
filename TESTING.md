# 🧪 FIAP Tech Challenge - Complete End-to-End Testing Guide

## 📋 Table of Contents

1. [Prerequisites](#prerequisites)
2. [AWS Configuration](#aws-configuration)
3. [Deployment](#deployment)
4. [Kubectl Configuration](#kubectl-configuration)
5. [Verify Deployment](#verify-deployment)
6. [Get Service URLs](#get-service-urls)
7. [Create Admin User](#create-admin-user)
8. [Test Authentication](#test-authentication)
9. [Test API Endpoints](#test-api-endpoints)
10. [Troubleshooting](#troubleshooting)
11. [Debugging Guide](#debugging-guide)

---

## Prerequisites

### Required Tools

Install these tools on your machine:

```bash
# 1. AWS CLI (v2)
# macOS:
brew install awscli

# Linux:
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip awscliv2.zip
sudo ./aws/install

# Verify:
aws --version
# Expected: aws-cli/2.x.x or higher

# 2. kubectl
# macOS:
brew install kubectl

# Linux:
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
chmod +x kubectl
sudo mv kubectl /usr/local/bin/

# Verify:
kubectl version --client
# Expected: Client Version: v1.28.x or higher

# 3. jq (JSON processor)
# macOS:
brew install jq

# Linux:
sudo apt-get install jq

# Verify:
jq --version
# Expected: jq-1.6 or higher

# 4. Node.js (for bcrypt password generation - optional)
# macOS:
brew install node

# Linux:
curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
sudo apt-get install -y nodejs

# Verify:
node --version
# Expected: v20.x or higher
```

---

## AWS Configuration

### Step 1: Get AWS Credentials

#### Option A: AWS Academy (Learner Lab)

If using **AWS Academy**:
1. Go to your AWS Academy course
2. Click "AWS Details"
3. Click "Show" next to "AWS CLI"
4. Copy the credentials block that looks like:

```bash
[default]
aws_access_key_id=ASIA...
aws_secret_access_key=...
aws_session_token=...
```

**⚠️ Note**: AWS Academy credentials include a session token and expire every 4 hours.

#### Option B: Regular AWS Account (IAM User)

If using a **regular AWS account**:

1. **Sign in to AWS Console**: Go to https://console.aws.amazon.com/
2. **Navigate to IAM**: Search for "IAM" in the top search bar
3. **Create/Select IAM User**:
   - Click "Users" in the left sidebar
   - If you don't have a user yet:
     - Click "Create user"
     - Enter username (e.g., "terraform-admin")
     - Click "Next"
     - Select "Attach policies directly"
     - Attach `AdministratorAccess` policy (for testing) or create custom policy
     - Click "Next" → "Create user"

4. **Create Access Keys**:
   - Click on your IAM user name
   - Go to "Security credentials" tab
   - Scroll to "Access keys" section
   - Click "Create access key"
   - Select "Command Line Interface (CLI)"
   - Check "I understand..." and click "Next"
   - Add optional description tag
   - Click "Create access key"

5. **Save Your Credentials**:
   ```
   Access key ID: AKIAIOSFODNN7EXAMPLE
   Secret access key: wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY
   ```

   **⚠️ IMPORTANT**: Save these now! AWS only shows the secret access key once.

6. **Download CSV** (optional but recommended): Click "Download .csv file"

**Credential Differences**:
- **AWS Academy**: Includes `aws_session_token`, expires in 4 hours
- **Regular AWS**: Only `access_key_id` and `secret_access_key`, never expires (until you rotate/delete them)

### Step 2: Configure AWS CLI

#### For AWS Academy (with session token):

```bash
# Open AWS credentials file
nano ~/.aws/credentials

# Or use vim if you prefer
vim ~/.aws/credentials

# Paste the credentials from AWS Academy
# It should look like:
[default]
aws_access_key_id=ASIAXXXXXXXXXXX
aws_secret_access_key=XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX
aws_session_token=FwoGZXIvYXdzE...very long token...
```

Save and exit (Ctrl+X, then Y, then Enter in nano).

#### For Regular AWS Account (without session token):

```bash
# Option 1: Use aws configure (interactive)
aws configure

# You'll be prompted for:
AWS Access Key ID [None]: AKIAIOSFODNN7EXAMPLE
AWS Secret Access Key [None]: wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY
Default region name [None]: us-east-1
Default output format [None]: json

# Option 2: Manually edit credentials file
nano ~/.aws/credentials

# Add:
[default]
aws_access_key_id=AKIAIOSFODNN7EXAMPLE
aws_secret_access_key=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY
# Note: NO aws_session_token line for regular AWS accounts
```

Save and exit (Ctrl+X, then Y, then Enter in nano).

### Step 3: Set AWS Region

```bash
# Configure region
aws configure set region us-east-1

# Verify configuration
aws sts get-caller-identity

# Expected output:
{
    "UserId": "AROAXXXXXXXXX:user",
    "Account": "305032652600",
    "Arn": "arn:aws:sts::305032652600:assumed-role/..."
}
```

**⚠️ Credential Expiration**:
- **AWS Academy**: Session tokens expire every 4 hours. You'll need to update credentials when you see authentication errors.
- **Regular AWS Account**: Access keys don't expire unless you manually rotate or delete them. No need to update credentials hourly.

---

## Deployment

### Option 1: Deploy All (Recommended)

Use the orchestrator to deploy everything in the correct order:

```bash
# Navigate to orchestrator
cd /Users/finha/code/personal/fiap/infra-orchestrator

# Trigger deployment via GitHub Actions
# Go to: https://github.com/fiap-tech-challenge-projects/infra-orchestrator/actions
# Click "Deploy All Infrastructure" → "Run workflow" → "Run workflow"

# Monitor progress
gh run watch --repo fiap-tech-challenge-projects/infra-orchestrator
```

The orchestrator will deploy in order:
1. **kubernetes-core-infra** (~15 minutes) - EKS cluster, VPC, networking
2. **kubernetes-addons** (~6 minutes) - Namespaces, Helm releases
3. **database-managed-infra** (~9 minutes) - RDS, Secrets Manager
4. **lambda-api-handler** (~5 minutes) - Auth Lambda, API Gateway
5. **k8s-main-service** (~11 minutes) - Main NestJS application

**Total time**: ~46 minutes

### Option 2: Deploy Individually

If you need to deploy or redeploy specific components:

```bash
# 1. Kubernetes Core Infrastructure
cd kubernetes-core-infra
git push  # Triggers GitHub Actions workflow

# 2. Kubernetes Addons (after core is ready)
cd kubernetes-addons
git push

# 3. Database (after addons)
cd database-managed-infra
git push

# 4. Lambda Auth (after database)
cd lambda-api-handler
git push

# 5. Main Service (after all above)
cd k8s-main-service
git push
```

**⚠️ Important**: Always deploy in this order due to dependencies!

---

## Kubectl Configuration

### Step 1: Update kubeconfig

After the EKS cluster is deployed, configure kubectl to connect to it:

```bash
# Navigate to kubernetes-core-infra
cd /Users/finha/code/personal/fiap/kubernetes-core-infra

# Run the configure script
./scripts/configure-kubectl.sh

# This script does:
# - Gets EKS cluster name from Terraform output
# - Updates ~/.kube/config with cluster credentials
# - Tests connection
```

**Expected output**:
```
✓ Found EKS cluster: fiap-tech-challenge-staging
✓ Updated kubeconfig
✓ Successfully connected to cluster

Current context: arn:aws:eks:us-east-1:305032652600:cluster/fiap-tech-challenge-staging

Cluster Info:
NAME                              STATUS   ROLES    AGE   VERSION
ip-10-0-1-123.ec2.internal        Ready    <none>   1d    v1.28.x
ip-10-0-2-456.ec2.internal        Ready    <none>   1d    v1.28.x
```

### Step 2: Verify kubectl Access

```bash
# Check cluster info
kubectl cluster-info

# Check nodes
kubectl get nodes

# Check namespaces
kubectl get namespaces

# Should see:
# - default
# - kube-system
# - ftc-app-staging
# - signoz
```

---

## Verify Deployment

### Check All Components

```bash
# 1. Check pods in staging namespace
kubectl get pods -n ftc-app-staging

# Expected:
NAME                                      READY   STATUS    RESTARTS   AGE
fiap-tech-challenge-api-xxxxxxxxx-xxxxx   1/1     Running   0          10m
fiap-tech-challenge-api-xxxxxxxxx-xxxxx   1/1     Running   0          10m

# 2. Check services
kubectl get svc -n ftc-app-staging

# Expected:
NAME                          TYPE        CLUSTER-IP       EXTERNAL-IP   PORT(S)
fiap-tech-challenge-api       ClusterIP   172.20.xxx.xxx   <none>        3000/TCP
fiap-tech-challenge-metrics   ClusterIP   172.20.xxx.xxx   <none>        9090/TCP

# 3. Check ingress (ALB)
kubectl get ingress -n ftc-app-staging

# Expected:
NAME                      CLASS   HOSTS   ADDRESS                                          PORTS   AGE
fiap-tech-challenge-api   alb     *       k8s-ftcappst-fiaptech-xxxxx.us-east-1.elb...    80      10m

# 4. Check secrets are synced
kubectl get externalsecret -n ftc-app-staging

# Expected:
NAME                    STORE                  REFRESH INTERVAL   STATUS         READY
auth-config             aws-secrets-manager    1h                 SecretSynced   True
database-credentials    aws-secrets-manager    1h                 SecretSynced   True

# 5. Check RDS database
aws rds describe-db-instances \
  --db-instance-identifier fiap-tech-challenge-staging-postgres \
  --query 'DBInstances[0].{Status:DBInstanceStatus,Endpoint:Endpoint.Address}' \
  --output table

# Expected:
---------------------------------------------------------------------
|                    DescribeDBInstances                            |
+------------+------------------------------------------------------+
|  Endpoint  |  fiap-tech-challenge-staging-postgres.cmfkkm...    |
|  Status    |  available                                           |
+------------+------------------------------------------------------+

# 6. Check Lambda functions
aws lambda list-functions \
  --query 'Functions[?contains(FunctionName, `fiap`)].FunctionName' \
  --output table

# Expected:
----------------------------------------------
|              ListFunctions                 |
+--------------------------------------------+
|  fiap-tech-challenge-staging-auth-handler  |
|  fiap-tech-challenge-staging-authorizer    |
+--------------------------------------------+
```

**✅ All checks should pass before proceeding!**

---

## Get Service URLs

### 1. API Gateway URL (Authentication)

```bash
# Get the correct API Gateway endpoint
aws apigatewayv2 get-apis \
  --query 'Items[?Name==`fiap-tech-challenge-staging-api`].{ApiEndpoint:ApiEndpoint}' \
  --output text

# Save it as a variable
export AUTH_API_URL="https://7q4ne49oie.execute-api.us-east-1.amazonaws.com/v1"

# Verify it works
curl -s $AUTH_API_URL/auth/login -X POST \
  -H "Content-Type: application/json" \
  -d '{"email":"test@test.com","password":"wrong"}' | jq '.'

# Expected: {"error":"INVALID_CREDENTIALS",...}
# (This is good - it means the Lambda is responding)
```

### 2. ALB URL (Main Application)

```bash
# Get ALB hostname
export ALB_HOST=$(kubectl get ingress fiap-tech-challenge-api \
  -n ftc-app-staging \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')

# Check if ALB is ready
echo "ALB Host: $ALB_HOST"

# If empty, wait a few minutes for ALB to provision
# Then run the command again

# Save as full URL
export APP_API_URL="http://$ALB_HOST/v1"

# Verify it's accessible (should return 401 without auth)
curl -s $APP_API_URL/clients | jq '.'

# Expected: {"statusCode":401,"error":"Unauthorized",...}
# (This is good - it means the app is running)
```

**⚠️ Note**: ALB can take 5-10 minutes to provision after deployment. If you get connection errors, wait and try again.

---

## Create Admin User

You need an admin user to test authentication. The application doesn't have a default admin, so we'll create one via database.

### Step 1: Verify Database Migrations Ran

```bash
# Create a debug job to check migrations
cat > /tmp/check-migrations.yaml << 'EOF'
apiVersion: batch/v1
kind: Job
metadata:
  name: check-migrations
  namespace: ftc-app-staging
spec:
  ttlSecondsAfterFinished: 300
  template:
    spec:
      restartPolicy: Never
      serviceAccountName: migration-service-account
      containers:
      - name: check
        image: 305032652600.dkr.ecr.us-east-1.amazonaws.com/database-migrations:staging
        command:
          - sh
          - -c
          - |
            set -e
            SECRET_JSON=$(aws secretsmanager get-secret-value \
              --secret-id fiap-tech-challenge/staging/database/credentials \
              --region us-east-1 \
              --query SecretString \
              --output text)

            DB_HOST=$(echo "$SECRET_JSON" | jq -r '.host')
            DB_PORT=$(echo "$SECRET_JSON" | jq -r '.port')
            DB_NAME=$(echo "$SECRET_JSON" | jq -r '.dbname')
            DB_USER=$(echo "$SECRET_JSON" | jq -r '.username')
            DB_PASS=$(echo "$SECRET_JSON" | jq -r '.password')
            export PGPASSWORD="$DB_PASS"

            echo "=== Database Tables ==="
            psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" \
              -c "SELECT tablename FROM pg_tables WHERE schemaname = 'public' ORDER BY tablename;"

            echo ""
            echo "=== Migration History ==="
            psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" \
              -c "SELECT migration_name, finished_at FROM _prisma_migrations ORDER BY finished_at;"
        env:
        - name: AWS_REGION
          value: "us-east-1"
EOF

# Apply the job
kubectl apply -f /tmp/check-migrations.yaml

# Wait for it to complete
kubectl wait --for=condition=complete --timeout=60s job/check-migrations -n ftc-app-staging

# Check the logs
kubectl logs job/check-migrations -n ftc-app-staging
```

**Expected output**: Should show ~17 tables including `users`, `clients`, `vehicles`, etc., and 10+ migrations.

### Step 2: Generate Password Hash

```bash
# Install bcryptjs if not already installed
npm install -g bcryptjs

# Generate hash for password "Admin123456"
node -e "const bcrypt = require('bcryptjs'); bcrypt.hash('Admin123456', 10).then(hash => console.log(hash));"

# Expected output (example):
# $2a$10$HRm9MVibbL2kBtO6v0h7we573tHx/sLFD7QaY2qr6saiUB0syEjBS

# Copy this hash - you'll use it in the next step
```

### Step 3: Create Admin User

```bash
# Replace $HASH with the hash from previous step
# IMPORTANT: Escape dollar signs with backslashes!

cat > /tmp/create-admin-user.yaml << 'EOF'
apiVersion: batch/v1
kind: Job
metadata:
  name: create-admin-user
  namespace: ftc-app-staging
spec:
  ttlSecondsAfterFinished: 300
  template:
    spec:
      restartPolicy: Never
      serviceAccountName: migration-service-account
      containers:
      - name: create-admin
        image: 305032652600.dkr.ecr.us-east-1.amazonaws.com/database-migrations:staging
        command:
          - sh
          - -c
          - |
            set -e
            SECRET_JSON=$(aws secretsmanager get-secret-value \
              --secret-id fiap-tech-challenge/staging/database/credentials \
              --region us-east-1 \
              --query SecretString \
              --output text)

            DB_HOST=$(echo "$SECRET_JSON" | jq -r '.host')
            DB_PORT=$(echo "$SECRET_JSON" | jq -r '.port')
            DB_NAME=$(echo "$SECRET_JSON" | jq -r '.dbname')
            DB_USER=$(echo "$SECRET_JSON" | jq -r '.username')
            DB_PASS=$(echo "$SECRET_JSON" | jq -r '.password')
            export PGPASSWORD="$DB_PASS"

            echo "Creating admin user..."
            psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -c "
              INSERT INTO users (id, email, password, role, \"isActive\", \"createdAt\", \"updatedAt\")
              VALUES (
                gen_random_uuid(),
                'admin@test.com',
                '\$2a\$10\$HRm9MVibbL2kBtO6v0h7we573tHx/sLFD7QaY2qr6saiUB0syEjBS',
                'ADMIN',
                true,
                NOW(),
                NOW()
              )
              ON CONFLICT (email) DO UPDATE SET
                password = EXCLUDED.password,
                \"updatedAt\" = NOW()
              RETURNING id, email, role, \"isActive\";
            "

            echo ""
            echo "Verifying admin user exists:"
            psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -c "
              SELECT id, email, role, \"isActive\", \"createdAt\"
              FROM users
              WHERE email = 'admin@test.com';
            "
        env:
        - name: AWS_REGION
          value: "us-east-1"
EOF

# Delete old job if it exists
kubectl delete job create-admin-user -n ftc-app-staging 2>/dev/null || true

# Apply the job
kubectl apply -f /tmp/create-admin-user.yaml

# Wait for completion
kubectl wait --for=condition=complete --timeout=60s job/create-admin-user -n ftc-app-staging

# Check the logs
kubectl logs job/create-admin-user -n ftc-app-staging
```

**Expected output**:
```
Creating admin user...
                  id                  |     email      | role  | isActive
--------------------------------------+----------------+-------+----------
 4fd79c48-891d-4ff1-949f-32b7501b3466 | admin@test.com | ADMIN | t

Verifying admin user exists:
                  id                  |     email      | role  | isActive |         createdAt
--------------------------------------+----------------+-------+----------+---------------------------
 4fd79c48-891d-4ff1-949f-32b7501b3466 | admin@test.com | ADMIN | t        | 2026-02-05 21:24:59.123456
```

**📝 Save these credentials:**
- **Email**: admin@test.com
- **Password**: Admin123456

---

## Test Authentication

Now let's test the complete JWT authentication flow.

### Test 1: Login

```bash
# Login to get JWT tokens
curl -s -X POST $AUTH_API_URL/auth/login \
  -H "Content-Type: application/json" \
  -d '{
    "email": "admin@test.com",
    "password": "Admin123456"
  }' | jq '.'
```

**Expected output**:
```json
{
  "accessToken": "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9...",
  "refreshToken": "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9...",
  "expiresIn": 900,
  "tokenType": "Bearer",
  "user": {
    "id": "4fd79c48-891d-4ff1-949f-32b7501b3466",
    "email": "admin@test.com",
    "name": "admin@test.com",
    "role": "ADMIN"
  }
}
```

### Test 2: Decode JWT Token

```bash
# Extract and decode the JWT
ACCESS_TOKEN=$(curl -s -X POST $AUTH_API_URL/auth/login \
  -H "Content-Type: application/json" \
  -d '{"email":"admin@test.com","password":"Admin123456"}' | jq -r '.accessToken')

# Decode JWT payload (base64url decode)
PAYLOAD=$(echo "$ACCESS_TOKEN" | cut -d. -f2)
PADDING=$((4 - ${#PAYLOAD} % 4))
if [ $PADDING -ne 4 ]; then
  PAYLOAD="${PAYLOAD}$(printf '=%.0s' $(seq 1 $PADDING))"
fi

echo "$PAYLOAD" | base64 -d 2>/dev/null | jq '.'
```

**Expected output**:
```json
{
  "sub": "4fd79c48-891d-4ff1-949f-32b7501b3466",
  "email": "admin@test.com",
  "name": "admin@test.com",
  "role": "ADMIN",
  "iat": 1770327034,
  "exp": 1770327934
}
```

### Test 3: Save Tokens for API Testing

```bash
# Get fresh tokens and extract user info
LOGIN_RESPONSE=$(curl -s -X POST $AUTH_API_URL/auth/login \
  -H "Content-Type: application/json" \
  -d '{"email":"admin@test.com","password":"Admin123456"}')

# Save access token
export ACCESS_TOKEN=$(echo "$LOGIN_RESPONSE" | jq -r '.accessToken')

# Extract user info from JWT
PAYLOAD=$(echo "$ACCESS_TOKEN" | cut -d. -f2)
PADDING=$((4 - ${#PAYLOAD} % 4))
if [ $PADDING -ne 4 ]; then
  PAYLOAD="${PAYLOAD}$(printf '=%.0s' $(seq 1 $PADDING))"
fi

export USER_ID=$(echo "$PAYLOAD" | base64 -d 2>/dev/null | jq -r '.sub')
export USER_EMAIL=$(echo "$PAYLOAD" | base64 -d 2>/dev/null | jq -r '.email')
export USER_ROLE=$(echo "$PAYLOAD" | base64 -d 2>/dev/null | jq -r '.role')

# Verify
echo "User ID: $USER_ID"
echo "Email: $USER_EMAIL"
echo "Role: $USER_ROLE"
echo "Token: ${ACCESS_TOKEN:0:50}..."
```

---

## Test API Endpoints

The k8s-main-service expects requests to include special headers that would normally be set by an API Gateway Lambda Authorizer. For testing, we'll add these headers manually.

### Understanding the Headers

The application expects these headers:
- `x-user-id`: User's unique ID (from JWT `sub` claim)
- `x-user-email`: User's email
- `x-user-role`: User's role (ADMIN, EMPLOYEE, CLIENT)
- `x-client-id`: Associated client ID (optional)
- `x-employee-id`: Associated employee ID (optional)

### Test 1: List Clients (Empty)

```bash
curl -s $APP_API_URL/clients \
  -H "x-user-id: $USER_ID" \
  -H "x-user-email: $USER_EMAIL" \
  -H "x-user-role: $USER_ROLE" \
  | jq '.'
```

**Expected output**:
```json
{
  "data": [],
  "meta": {
    "total": 0,
    "page": 1,
    "limit": 10,
    "totalPages": 0,
    "hasNext": false,
    "hasPrev": false
  }
}
```

### Test 2: Create a Client

```bash
curl -s -X POST $APP_API_URL/clients \
  -H "Content-Type: application/json" \
  -H "x-user-id: $USER_ID" \
  -H "x-user-email: $USER_EMAIL" \
  -H "x-user-role: $USER_ROLE" \
  -d '{
    "name": "João Silva",
    "email": "joao.silva@example.com",
    "cpfCnpj": "111.444.777-35",
    "phone": "+5511999999999",
    "address": "Rua Teste, 123 - São Paulo, SP"
  }' | jq '.'
```

**Expected output**:
```json
{
  "id": "cml9z1dk20000qb01nufpko2t",
  "name": "João Silva",
  "email": "joao.silva@example.com",
  "cpfCnpj": "111.444.777-35",
  "phone": "+55 11 99999 9999",
  "address": "Rua Teste, 123 - São Paulo, SP",
  "createdAt": "2026-02-05T21:30:57.000Z",
  "updatedAt": "2026-02-05T21:30:57.000Z"
}
```

### Test 3: Get Client by ID

```bash
# Save the client ID from previous response
export CLIENT_ID="cml9z1dk20000qb01nufpko2t"  # Use your actual ID

curl -s $APP_API_URL/clients/$CLIENT_ID \
  -H "x-user-id: $USER_ID" \
  -H "x-user-email: $USER_EMAIL" \
  -H "x-user-role: $USER_ROLE" \
  | jq '.'
```

### Test 4: Create a Vehicle

```bash
curl -s -X POST $APP_API_URL/vehicles \
  -H "Content-Type: application/json" \
  -H "x-user-id: $USER_ID" \
  -H "x-user-email: $USER_EMAIL" \
  -H "x-user-role: $USER_ROLE" \
  -d "{
    \"licensePlate\": \"ABC1234\",
    \"make\": \"Toyota\",
    \"model\": \"Corolla\",
    \"year\": 2023,
    \"color\": \"Silver\",
    \"clientId\": \"$CLIENT_ID\"
  }" | jq '.'
```

**Expected output**:
```json
{
  "id": "cml9z1ec60001s401egdp9jlp",
  "licensePlate": "ABC-1234",
  "make": "Toyota",
  "model": "Corolla",
  "year": 2023,
  "color": "Silver",
  "clientId": "cml9z1dk20000qb01nufpko2t",
  "createdAt": "2026-02-05T21:31:12.000Z",
  "updatedAt": "2026-02-05T21:31:12.000Z"
}
```

### Test 5: List All Clients (Should Show 1)

```bash
curl -s $APP_API_URL/clients \
  -H "x-user-id: $USER_ID" \
  -H "x-user-email: $USER_EMAIL" \
  -H "x-user-role: $USER_ROLE" \
  | jq '{total: .meta.total, clients: [.data[] | {id, name, email}]}'
```

### Complete Test Script

Save this as `test-api.sh`:

```bash
#!/bin/bash

set -e

echo "=== FIAP Tech Challenge - Complete API Test ==="
echo ""

# Colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Get API URLs
export AUTH_API_URL="https://7q4ne49oie.execute-api.us-east-1.amazonaws.com/v1"
export ALB_HOST=$(kubectl get ingress fiap-tech-challenge-api -n ftc-app-staging -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
export APP_API_URL="http://$ALB_HOST/v1"

echo "Auth API: $AUTH_API_URL"
echo "App API: $APP_API_URL"
echo ""

# Step 1: Login
echo "Step 1: Login with admin credentials"
LOGIN_RESPONSE=$(curl -s -X POST $AUTH_API_URL/auth/login \
  -H "Content-Type: application/json" \
  -d '{"email":"admin@test.com","password":"Admin123456"}')

export ACCESS_TOKEN=$(echo "$LOGIN_RESPONSE" | jq -r '.accessToken')

# Extract user info
PAYLOAD=$(echo "$ACCESS_TOKEN" | cut -d. -f2)
PADDING=$((4 - ${#PAYLOAD} % 4))
if [ $PADDING -ne 4 ]; then
  PAYLOAD="${PAYLOAD}$(printf '=%.0s' $(seq 1 $PADDING))"
fi

export USER_ID=$(echo "$PAYLOAD" | base64 -d 2>/dev/null | jq -r '.sub')
export USER_EMAIL=$(echo "$PAYLOAD" | base64 -d 2>/dev/null | jq -r '.email')
export USER_ROLE=$(echo "$PAYLOAD" | base64 -d 2>/dev/null | jq -r '.role')

echo -e "${GREEN}✓${NC} Logged in as: $USER_EMAIL ($USER_ROLE)"
echo ""

# Step 2: List clients
echo "Step 2: List clients (should be empty initially)"
CLIENTS=$(curl -s $APP_API_URL/clients \
  -H "x-user-id: $USER_ID" \
  -H "x-user-email: $USER_EMAIL" \
  -H "x-user-role: $USER_ROLE")

TOTAL=$(echo "$CLIENTS" | jq -r '.meta.total')
echo -e "${GREEN}✓${NC} Found $TOTAL clients"
echo ""

# Step 3: Create a client
echo "Step 3: Create a new client"
CREATE_RESPONSE=$(curl -s -X POST $APP_API_URL/clients \
  -H "Content-Type: application/json" \
  -H "x-user-id: $USER_ID" \
  -H "x-user-email: $USER_EMAIL" \
  -H "x-user-role: $USER_ROLE" \
  -d '{
    "name": "João Silva",
    "email": "joao.silva@example.com",
    "cpfCnpj": "111.444.777-35",
    "phone": "+5511999999999",
    "address": "Rua Teste, 123 - São Paulo, SP"
  }')

CLIENT_ID=$(echo "$CREATE_RESPONSE" | jq -r '.id // empty')

if [ -n "$CLIENT_ID" ] && [ "$CLIENT_ID" != "null" ]; then
  echo -e "${GREEN}✓${NC} Client created successfully"
  echo "$CREATE_RESPONSE" | jq '{id, name, email, cpfCnpj}'
else
  echo -e "${RED}✗${NC} Failed to create client:"
  echo "$CREATE_RESPONSE" | jq '.'
  exit 1
fi
echo ""

# Step 4: Get client by ID
echo "Step 4: Get client by ID"
curl -s $APP_API_URL/clients/$CLIENT_ID \
  -H "x-user-id: $USER_ID" \
  -H "x-user-email: $USER_EMAIL" \
  -H "x-user-role: $USER_ROLE" | jq '{id, name, email, cpfCnpj, phone}'
echo ""

# Step 5: Create a vehicle
echo "Step 5: Create a vehicle for the client"
VEHICLE_RESPONSE=$(curl -s -X POST $APP_API_URL/vehicles \
  -H "Content-Type: application/json" \
  -H "x-user-id: $USER_ID" \
  -H "x-user-email: $USER_EMAIL" \
  -H "x-user-role: $USER_ROLE" \
  -d "{
    \"licensePlate\": \"ABC1234\",
    \"make\": \"Toyota\",
    \"model\": \"Corolla\",
    \"year\": 2023,
    \"color\": \"Silver\",
    \"clientId\": \"$CLIENT_ID\"
  }")

VEHICLE_ID=$(echo "$VEHICLE_RESPONSE" | jq -r '.id // empty')

if [ -n "$VEHICLE_ID" ] && [ "$VEHICLE_ID" != "null" ]; then
  echo -e "${GREEN}✓${NC} Vehicle created successfully"
  echo "$VEHICLE_RESPONSE" | jq '{id, licensePlate, make, model, year}'
else
  echo -e "${RED}✗${NC} Failed to create vehicle:"
  echo "$VEHICLE_RESPONSE" | jq '.'
fi
echo ""

# Step 6: List clients again
echo "Step 6: List all clients (should show 1 now)"
curl -s $APP_API_URL/clients \
  -H "x-user-id: $USER_ID" \
  -H "x-user-email: $USER_EMAIL" \
  -H "x-user-role: $USER_ROLE" | jq '{total: .meta.total, clients: [.data[] | {id, name, email}]}'
echo ""

echo -e "${GREEN}=== ALL TESTS PASSED ===${NC}"
```

Make it executable and run:

```bash
chmod +x test-api.sh
./test-api.sh
```

---

## Troubleshooting

### Common Issues and Solutions

#### 1. "Command not found: aws"

**Problem**: AWS CLI not installed.

**Solution**:
```bash
# macOS
brew install awscli

# Linux
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip awscliv2.zip
sudo ./aws/install
```

#### 2. "Unable to locate credentials"

**Problem**: AWS credentials not configured or expired.

**Solution**:
```bash
# Check current credentials
aws sts get-caller-identity

# If this fails, check which type of AWS account you're using:

# For AWS Academy (credentials expired after 4 hours):
# 1. Go to AWS Academy
# 2. Click "AWS Details" → "Show"
# 3. Copy NEW credentials
# 4. Update ~/.aws/credentials
nano ~/.aws/credentials
# Paste the new credentials (including the new session token)

# For Regular AWS Account (credentials not configured):
# Option 1: Use aws configure
aws configure
# Enter your Access Key ID and Secret Access Key

# Option 2: Manually edit credentials file
nano ~/.aws/credentials
# Add:
# [default]
# aws_access_key_id=YOUR_ACCESS_KEY
# aws_secret_access_key=YOUR_SECRET_KEY
```

#### 3. "error: You must be logged in to the server"

**Problem**: kubectl not configured for EKS cluster.

**Solution**:
```bash
cd /Users/finha/code/personal/fiap/kubernetes-core-infra
./scripts/configure-kubectl.sh

# Verify
kubectl get nodes
```

#### 4. "No resources found in ftc-app-staging namespace"

**Problem**: Application not deployed yet or wrong namespace.

**Solution**:
```bash
# Check if namespace exists
kubectl get namespaces | grep ftc-app

# If namespace exists but empty, check deployment
kubectl get deployments -n ftc-app-staging

# If no deployments, redeploy k8s-main-service
cd /Users/finha/code/personal/fiap/k8s-main-service
git push  # Triggers deployment
```

#### 5. "Internal Server Error" from Lambda

**Problem**: Lambda function errors - could be database connection, missing dependencies, or code errors.

**Solution**:
```bash
# Check Lambda logs
aws logs tail /aws/lambda/fiap-tech-challenge-staging-auth-handler --since 10m

# Common causes:
# - Missing bcryptjs dependency (should be fixed)
# - Database connection SSL error (should be fixed)
# - Schema mismatch (should be fixed)

# If needed, redeploy Lambda
cd /Users/finha/code/personal/fiap/lambda-api-handler
git push
```

#### 6. "INVALID_CREDENTIALS" when logging in

**Problem**: Wrong password or admin user not created.

**Solution**:
```bash
# Verify admin user exists
cat > /tmp/check-admin.yaml << 'EOF'
apiVersion: batch/v1
kind: Job
metadata:
  name: check-admin
  namespace: ftc-app-staging
spec:
  ttlSecondsAfterFinished: 300
  template:
    spec:
      restartPolicy: Never
      serviceAccountName: migration-service-account
      containers:
      - name: check
        image: 305032652600.dkr.ecr.us-east-1.amazonaws.com/database-migrations:staging
        command:
          - sh
          - -c
          - |
            SECRET_JSON=$(aws secretsmanager get-secret-value --secret-id fiap-tech-challenge/staging/database/credentials --region us-east-1 --query SecretString --output text)
            DB_HOST=$(echo "$SECRET_JSON" | jq -r '.host')
            DB_PORT=$(echo "$SECRET_JSON" | jq -r '.port')
            DB_NAME=$(echo "$SECRET_JSON" | jq -r '.dbname')
            DB_USER=$(echo "$SECRET_JSON" | jq -r '.username')
            DB_PASS=$(echo "$SECRET_JSON" | jq -r '.password')
            export PGPASSWORD="$DB_PASS"

            psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -c "SELECT id, email, role, \"isActive\" FROM users WHERE email = 'admin@test.com';"
        env:
        - name: AWS_REGION
          value: "us-east-1"
EOF

kubectl delete job check-admin -n ftc-app-staging 2>/dev/null || true
kubectl apply -f /tmp/check-admin.yaml
sleep 5
kubectl logs job/check-admin -n ftc-app-staging

# If no user found, go back to "Create Admin User" section
```

#### 7. "Missing authentication headers" (401)

**Problem**: Calling API without required headers.

**Solution**:
The k8s-main-service expects these headers:
- `x-user-id`
- `x-user-email`
- `x-user-role`

Always include them:
```bash
curl $APP_API_URL/clients \
  -H "x-user-id: $USER_ID" \
  -H "x-user-email: $USER_EMAIL" \
  -H "x-user-role: $USER_ROLE"
```

#### 8. "Connection refused" or "Connection timed out"

**Problem**: Service not accessible or wrong URL.

**Solution**:
```bash
# Check ALB status
kubectl get ingress -n ftc-app-staging

# Check if pods are running
kubectl get pods -n ftc-app-staging

# Check pod logs for errors
kubectl logs -n ftc-app-staging -l app=fiap-tech-challenge-api --tail=50

# If ALB address is empty, wait 5-10 minutes for it to provision
```

#### 9. "cpfCnpj must be a valid Brazilian CPF or CNPJ"

**Problem**: Invalid CPF/CNPJ format.

**Solution**:
Use a valid format:
- **CPF**: `111.444.777-35` (11 digits with dots and dash)
- **CNPJ**: `12.345.678/0001-90` (14 digits with dots, slash, and dash)

The application validates the format AND checksum!

#### 10. Pods in "CrashLoopBackOff" state

**Problem**: Application failing to start.

**Solution**:
```bash
# Check pod logs
kubectl logs -n ftc-app-staging -l app=fiap-tech-challenge-api --tail=100

# Common causes:
# - Database connection failed (check secrets)
# - Missing environment variables
# - Application error on startup

# Check secrets are synced
kubectl get externalsecret -n ftc-app-staging

# If not synced, check IRSA configuration
kubectl get serviceaccount -n ftc-app-staging
kubectl describe serviceaccount migration-service-account -n ftc-app-staging
```

---

## Debugging Guide

### How to Check Logs

#### 1. Application Logs (k8s-main-service)

```bash
# Get logs from all pods
kubectl logs -n ftc-app-staging -l app=fiap-tech-challenge-api --tail=100

# Follow logs in real-time
kubectl logs -n ftc-app-staging -l app=fiap-tech-challenge-api -f

# Get logs from specific pod
kubectl get pods -n ftc-app-staging
kubectl logs -n ftc-app-staging fiap-tech-challenge-api-xxxxxxxxx-xxxxx

# Get logs from previous pod instance (if crashed)
kubectl logs -n ftc-app-staging fiap-tech-challenge-api-xxxxxxxxx-xxxxx --previous
```

#### 2. Lambda Logs (auth-handler)

```bash
# Get recent logs
aws logs tail /aws/lambda/fiap-tech-challenge-staging-auth-handler --since 10m

# Follow logs in real-time
aws logs tail /aws/lambda/fiap-tech-challenge-staging-auth-handler --follow

# Search for errors
aws logs tail /aws/lambda/fiap-tech-challenge-staging-auth-handler --since 1h \
  | grep -i "error"
```

#### 3. Database Migration Logs

```bash
# Check if migrations ran
kubectl get jobs -n ftc-app-staging

# Get logs from migration job
kubectl logs job/database-migration -n ftc-app-staging

# Check migration history in database (via debug job)
# See "Verify Database Migrations Ran" section above
```

### How to Check Database

#### Connect to Database

```bash
# Create a debug pod with psql
cat > /tmp/db-debug.yaml << 'EOF'
apiVersion: batch/v1
kind: Job
metadata:
  name: db-debug
  namespace: ftc-app-staging
spec:
  ttlSecondsAfterFinished: 300
  template:
    spec:
      restartPolicy: Never
      serviceAccountName: migration-service-account
      containers:
      - name: debug
        image: 305032652600.dkr.ecr.us-east-1.amazonaws.com/database-migrations:staging
        command:
          - sh
          - -c
          - |
            SECRET_JSON=$(aws secretsmanager get-secret-value --secret-id fiap-tech-challenge/staging/database/credentials --region us-east-1 --query SecretString --output text)
            DB_HOST=$(echo "$SECRET_JSON" | jq -r '.host')
            DB_PORT=$(echo "$SECRET_JSON" | jq -r '.port')
            DB_NAME=$(echo "$SECRET_JSON" | jq -r '.dbname')
            DB_USER=$(echo "$SECRET_JSON" | jq -r '.username')
            DB_PASS=$(echo "$SECRET_JSON" | jq -r '.password')
            export PGPASSWORD="$DB_PASS"

            echo "=== Tables ==="
            psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -c "\dt"

            echo ""
            echo "=== Users ==="
            psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -c "SELECT id, email, role, \"isActive\" FROM users;"

            echo ""
            echo "=== Clients ==="
            psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -c "SELECT id, name, email FROM clients LIMIT 5;"

            echo ""
            echo "=== Vehicles ==="
            psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -c "SELECT id, \"licensePlate\", make, model FROM vehicles LIMIT 5;"
        env:
        - name: AWS_REGION
          value: "us-east-1"
EOF

kubectl delete job db-debug -n ftc-app-staging 2>/dev/null || true
kubectl apply -f /tmp/db-debug.yaml
sleep 5
kubectl logs job/db-debug -n ftc-app-staging
```

#### Run Custom SQL Query

```bash
# Modify the SQL in the command section above
# Example: Check service orders
echo "=== Service Orders ==="
psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -c "SELECT * FROM service_orders LIMIT 5;"
```

### How to Check Kubernetes Resources

#### Check Pod Status and Events

```bash
# Get detailed pod information
kubectl describe pod -n ftc-app-staging -l app=fiap-tech-challenge-api

# Check recent events
kubectl get events -n ftc-app-staging --sort-by='.lastTimestamp' | tail -20

# Check resource usage
kubectl top pods -n ftc-app-staging

# Check if pods are being OOMKilled
kubectl get pods -n ftc-app-staging -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.containerStatuses[0].lastState.terminated.reason}{"\n"}{end}'
```

#### Check Secrets

```bash
# Check if external secrets are synced
kubectl get externalsecret -n ftc-app-staging

# Get detailed status
kubectl describe externalsecret database-credentials -n ftc-app-staging
kubectl describe externalsecret auth-config -n ftc-app-staging

# Check secret store
kubectl describe secretstore aws-secrets-manager -n ftc-app-staging
```

#### Check Ingress/ALB

```bash
# Check ingress status
kubectl describe ingress fiap-tech-challenge-api -n ftc-app-staging

# Check ALB target health
aws elbv2 describe-target-health \
  --target-group-arn $(aws elbv2 describe-target-groups \
    --query 'TargetGroups[?contains(TargetGroupName, `k8s-ftcappst`)].TargetGroupArn' \
    --output text) \
  --query 'TargetHealthDescriptions[*].{Target:Target.Id,Health:TargetHealth.State,Reason:TargetHealth.Reason}' \
  --output table
```

### How to Check Lambda Functions

#### Check Lambda Configuration

```bash
# Get Lambda function details
aws lambda get-function --function-name fiap-tech-challenge-staging-auth-handler

# Check Lambda environment variables
aws lambda get-function-configuration \
  --function-name fiap-tech-challenge-staging-auth-handler \
  --query 'Environment.Variables'

# Check Lambda VPC configuration
aws lambda get-function-configuration \
  --function-name fiap-tech-challenge-staging-auth-handler \
  --query '{VpcId:VpcConfig.VpcId,Subnets:VpcConfig.SubnetIds,SecurityGroups:VpcConfig.SecurityGroupIds}'
```

#### Invoke Lambda Directly

```bash
# Test Lambda function directly
aws lambda invoke \
  --function-name fiap-tech-challenge-staging-auth-handler \
  --payload '{"body":"{\"email\":\"admin@test.com\",\"password\":\"Admin123456\"}","path":"/auth/login","httpMethod":"POST"}' \
  /tmp/lambda-response.json

# Check response
cat /tmp/lambda-response.json | jq '.'
```

### Performance Monitoring

#### Check Application Metrics

```bash
# Get pod metrics
kubectl top pods -n ftc-app-staging

# Check HPA status
kubectl get hpa -n ftc-app-staging

# Describe HPA for detailed metrics
kubectl describe hpa fiap-tech-challenge-api -n ftc-app-staging
```

#### Check Database Performance

```bash
# Get RDS metrics (CPU, connections, etc.)
aws cloudwatch get-metric-statistics \
  --namespace AWS/RDS \
  --metric-name CPUUtilization \
  --dimensions Name=DBInstanceIdentifier,Value=fiap-tech-challenge-staging-postgres \
  --start-time $(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%S) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%S) \
  --period 300 \
  --statistics Average \
  --query 'Datapoints[*].{Time:Timestamp,CPU:Average}' \
  --output table
```

---

## Architecture Flow

Understanding the complete flow helps with debugging:

```
┌─────────────────────────────────────────────────────────────────────┐
│                           CLIENT REQUEST                             │
└─────────────────────────────────────────────────────────────────────┘
                                 │
                                 ▼
    ┌────────────────────────────────────────────────────────────┐
    │                    1. LOGIN REQUEST                        │
    │   POST /v1/auth/login                                      │
    │   {"email": "admin@test.com", "password": "Admin123456"}   │
    └────────────────────────────────────────────────────────────┘
                                 │
                                 ▼
    ┌────────────────────────────────────────────────────────────┐
    │              API GATEWAY (Auth Endpoint)                   │
    │   https://7q4ne49oie.execute-api.us-east-1...              │
    │   - Routes request to Lambda                               │
    │   - No authorizer on /auth/* endpoints                     │
    └────────────────────────────────────────────────────────────┘
                                 │
                                 ▼
    ┌────────────────────────────────────────────────────────────┐
    │          Lambda: fiap-tech-challenge-staging-              │
    │                    auth-handler                            │
    │   - Extracts email & password                              │
    │   - Queries database for user                              │
    │   - Validates password with bcrypt                         │
    │   - Generates JWT tokens (access + refresh)                │
    └────────────────────────────────────────────────────────────┘
                                 │
                                 ▼
    ┌────────────────────────────────────────────────────────────┐
    │              AWS Secrets Manager (IRSA)                    │
    │   - JWT_SECRET for token signing                           │
    │   - DATABASE_URL for connection                            │
    └────────────────────────────────────────────────────────────┘
                                 │
                                 ▼
    ┌────────────────────────────────────────────────────────────┐
    │            RDS PostgreSQL (with SSL)                       │
    │   - Query: SELECT * FROM users WHERE email = ?             │
    │   - Returns: id, email, password, role, isActive           │
    └────────────────────────────────────────────────────────────┘
                                 │
                                 ▼
    ┌────────────────────────────────────────────────────────────┐
    │                    2. LOGIN RESPONSE                       │
    │   {                                                        │
    │     "accessToken": "eyJhbGc...",  // Valid 15 min         │
    │     "refreshToken": "eyJhbGc...", // Valid 7 days         │
    │     "user": {...}                                          │
    │   }                                                        │
    └────────────────────────────────────────────────────────────┘
                                 │
                                 ▼
    ┌────────────────────────────────────────────────────────────┐
    │              3. DECODE JWT (Client-side)                   │
    │   Extract user info from token payload:                    │
    │   - sub (user ID)                                          │
    │   - email                                                  │
    │   - role                                                   │
    └────────────────────────────────────────────────────────────┘
                                 │
                                 ▼
    ┌────────────────────────────────────────────────────────────┐
    │              4. API REQUEST (with headers)                 │
    │   GET /v1/clients                                          │
    │   Headers:                                                 │
    │     x-user-id: 4fd79c48-891d-4ff1-949f-32b7501b3466       │
    │     x-user-email: admin@test.com                           │
    │     x-user-role: ADMIN                                     │
    └────────────────────────────────────────────────────────────┘
                                 │
                                 ▼
    ┌────────────────────────────────────────────────────────────┐
    │                 ALB (Application Load Balancer)            │
    │   k8s-ftcappst-fiaptech-6c502e19ef-86518592...            │
    │   - Routes to healthy pods only                            │
    └────────────────────────────────────────────────────────────┘
                                 │
                                 ▼
    ┌────────────────────────────────────────────────────────────┐
    │           Kubernetes Pods (NestJS Application)             │
    │   - ApiGatewayAuthGuard checks headers                     │
    │   - Extracts user info from headers                        │
    │   - Attaches to request.user                               │
    │   - Processes business logic                               │
    │   - Returns response                                       │
    └────────────────────────────────────────────────────────────┘
                                 │
                                 ▼
    ┌────────────────────────────────────────────────────────────┐
    │                    5. API RESPONSE                         │
    │   {                                                        │
    │     "data": [...],                                         │
    │     "meta": {...}                                          │
    │   }                                                        │
    └────────────────────────────────────────────────────────────┘
```

---

## Quick Reference

### Essential URLs

```bash
# Auth API (Lambda)
export AUTH_API_URL="https://7q4ne49oie.execute-api.us-east-1.amazonaws.com/v1"

# Main API (k8s-main-service via ALB)
export ALB_HOST=$(kubectl get ingress fiap-tech-challenge-api -n ftc-app-staging -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
export APP_API_URL="http://$ALB_HOST/v1"
```

### Essential Credentials

```bash
# Admin User
Email: admin@test.com
Password: Admin123456

# AWS Region
us-east-1

# Namespace
ftc-app-staging
```

### Essential Commands

```bash
# Get fresh JWT token
curl -s -X POST $AUTH_API_URL/auth/login \
  -H "Content-Type: application/json" \
  -d '{"email":"admin@test.com","password":"Admin123456"}' | jq '.'

# Extract user info from JWT
PAYLOAD=$(echo "$ACCESS_TOKEN" | cut -d. -f2)
PADDING=$((4 - ${#PAYLOAD} % 4))
[ $PADDING -ne 4 ] && PAYLOAD="${PAYLOAD}$(printf '=%.0s' $(seq 1 $PADDING))"
echo "$PAYLOAD" | base64 -d 2>/dev/null | jq '.'

# Make authenticated API call
curl -s $APP_API_URL/clients \
  -H "x-user-id: $USER_ID" \
  -H "x-user-email: $USER_EMAIL" \
  -H "x-user-role: $USER_ROLE" | jq '.'

# Check pod logs
kubectl logs -n ftc-app-staging -l app=fiap-tech-challenge-api --tail=50

# Check Lambda logs
aws logs tail /aws/lambda/fiap-tech-challenge-staging-auth-handler --since 10m

# Check database
# (Use db-debug.yaml from "How to Check Database" section)
```
