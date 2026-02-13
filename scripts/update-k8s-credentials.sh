#!/bin/bash
# =============================================================================
# Update AWS Credentials for Phase 4 Services
# =============================================================================
# Syncs AWS credentials from your local machine to Kubernetes secrets
# for all services that need to interact with AWS (EventBridge, SQS)
# =============================================================================

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration
SERVICES=("os-service" "billing-service" "execution-service")
ENVIRONMENT="${1:-development}"
NAMESPACE="ftc-app-${ENVIRONMENT}"
REGION="${AWS_REGION:-us-east-1}"

echo "======================================"
echo "AWS Credentials Sync to Kubernetes"
echo "======================================"
echo ""

# Get AWS credentials from local config
ACCESS_KEY=$(aws configure get aws_access_key_id)
SECRET_KEY=$(aws configure get aws_secret_access_key)

# Try to get session token (AWS Academy uses this)
SESSION_TOKEN=""
if [ -f ~/.aws/credentials ]; then
  SESSION_TOKEN=$(grep 'aws_session_token' ~/.aws/credentials | head -1 | cut -d'=' -f2 | tr -d ' ')
fi

# If not in credentials file, try environment
if [ -z "$SESSION_TOKEN" ]; then
  SESSION_TOKEN=$AWS_SESSION_TOKEN
fi

# Validate credentials
if [ -z "$ACCESS_KEY" ] || [ -z "$SECRET_KEY" ]; then
  echo -e "${RED}Error: AWS credentials not found${NC}"
  echo "Please configure AWS CLI first:"
  echo "  aws configure"
  exit 1
fi

echo -e "${GREEN}AWS credentials found${NC}"
echo "  Access Key: ${ACCESS_KEY:0:10}..."
echo "  Secret Key: ${SECRET_KEY:0:10}..."
if [ -n "$SESSION_TOKEN" ]; then
  echo "  Session Token: ${SESSION_TOKEN:0:20}..."
fi
echo ""

# Update credentials for each service
for SERVICE in "${SERVICES[@]}"; do
  echo "Updating AWS credentials for ${SERVICE}..."

  # Remove IRSA annotation if exists
  kubectl annotate serviceaccount "${SERVICE}" -n "${NAMESPACE}" \
    eks.amazonaws.com/role-arn- \
    2>/dev/null || true

  # Create or update secret
  SECRET_NAME="${SERVICE}-aws-creds"

  if [ -n "$SESSION_TOKEN" ]; then
    kubectl create secret generic "${SECRET_NAME}" -n "${NAMESPACE}" \
      --from-literal=AWS_ACCESS_KEY_ID="${ACCESS_KEY}" \
      --from-literal=AWS_SECRET_ACCESS_KEY="${SECRET_KEY}" \
      --from-literal=AWS_SESSION_TOKEN="${SESSION_TOKEN}" \
      --from-literal=AWS_REGION="${REGION}" \
      --dry-run=client -o yaml | kubectl apply -f -
  else
    kubectl create secret generic "${SECRET_NAME}" -n "${NAMESPACE}" \
      --from-literal=AWS_ACCESS_KEY_ID="${ACCESS_KEY}" \
      --from-literal=AWS_SECRET_ACCESS_KEY="${SECRET_KEY}" \
      --from-literal=AWS_REGION="${REGION}" \
      --dry-run=client -o yaml | kubectl apply -f -
  fi

  echo -e "${GREEN}  Secret ${SECRET_NAME} created/updated${NC}"

  # Restart deployment if it exists to pick up new credentials
  if kubectl get deployment "${SERVICE}" -n "${NAMESPACE}" &> /dev/null; then
    kubectl rollout restart "deployment/${SERVICE}" -n "${NAMESPACE}" &> /dev/null
    echo -e "${GREEN}  Deployment restarted to pick up new credentials${NC}"
  else
    echo -e "${YELLOW}  Deployment ${SERVICE} not found, skipping restart${NC}"
  fi

  echo ""
done

echo -e "${GREEN}AWS credentials updated for all services${NC}"
echo ""
echo "Note: AWS Academy session tokens expire after ~4 hours."
echo "Re-run this script when you get authentication errors."
echo ""
echo "To verify credentials are working:"
echo "  kubectl logs -n ${NAMESPACE} -l app=os-service --tail=20"
