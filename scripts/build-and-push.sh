#!/bin/bash
# Build and push Docker images for all Phase 4 microservices
# Usage: ./build-and-push.sh [--env=<development|production>]

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m' # No Color

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ENVIRONMENT="development"

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --env=*|--environment=*)
      ENVIRONMENT="${1#*=}"
      shift
      ;;
    *)
      echo "Unknown option: $1"
      exit 1
      ;;
  esac
done

# Validate environment
if [[ "$ENVIRONMENT" != "development" && "$ENVIRONMENT" != "production" ]]; then
    echo -e "${RED}Invalid environment: $ENVIRONMENT (must be 'development' or 'production')${NC}"
    exit 1
fi

# Set tag prefix based on environment
if [ "$ENVIRONMENT" = "production" ]; then
    TAG_PREFIX=""
else
    TAG_PREFIX="dev-"
fi

echo "=================================================="
echo "Phase 4 Microservices - Docker Build & Push"
echo "  Environment: $ENVIRONMENT"
echo "=================================================="
echo ""

# Get AWS account details
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REGION="${AWS_REGION:-us-east-1}"
ECR_URL="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"

echo "AWS Account ID: ${ACCOUNT_ID}"
echo "ECR Region: ${REGION}"
echo "ECR URL: ${ECR_URL}"
echo ""

# Login to ECR
echo "Logging in to Amazon ECR..."
aws ecr get-login-password --region "${REGION}" | \
    docker login --username AWS --password-stdin "${ECR_URL}"
echo -e "${GREEN}  Logged in to ECR${NC}"
echo ""

# Build and push services
SERVICES=("os-service" "billing-service" "execution-service")

for i in "${!SERVICES[@]}"; do
    svc="${SERVICES[$i]}"
    idx=$((i + 1))
    total=${#SERVICES[@]}

    echo "=================================================="
    echo "${idx}/${total} Building ${svc}"
    echo "=================================================="

    cd "${PROJECT_ROOT}/${svc}"
    TAG="${TAG_PREFIX}latest"

    echo "Building Docker image for linux/amd64..."
    docker build --platform linux/amd64 -t "${svc}:${TAG}" .

    echo "Tagging image for ECR..."
    docker tag "${svc}:${TAG}" "${ECR_URL}/${svc}:${TAG}"
    docker tag "${svc}:${TAG}" "${ECR_URL}/${svc}:latest"

    echo "Pushing to ECR..."
    docker push "${ECR_URL}/${svc}:${TAG}"
    docker push "${ECR_URL}/${svc}:latest"

    echo -e "${GREEN}  ${svc} pushed successfully${NC}"
    echo ""
done

# Summary
echo "=================================================="
echo "All images built and pushed successfully!"
echo "=================================================="
echo ""
echo "Images in ECR:"
for svc in "${SERVICES[@]}"; do
    TAG="${TAG_PREFIX}latest"
    echo "  - ${ECR_URL}/${svc}:${TAG}"
done
echo ""
