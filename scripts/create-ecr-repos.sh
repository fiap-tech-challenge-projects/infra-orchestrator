#!/bin/bash
# Create ECR repositories for Phase 4 microservices
# Usage: ./create-ecr-repos.sh

set -e

REGION="${AWS_REGION:-us-east-1}"

echo "Creating ECR repositories for microservices..."

SERVICES=("os-service" "billing-service" "execution-service")

for i in "${!SERVICES[@]}"; do
    svc="${SERVICES[$i]}"
    idx=$((i + 1))
    total=${#SERVICES[@]}

    echo "${idx}/${total} Creating ${svc} repository..."
    if aws ecr describe-repositories --repository-names "${svc}" --region "${REGION}" 2>/dev/null; then
        echo "   ${svc} repository already exists"
    else
        aws ecr create-repository \
            --repository-name "${svc}" \
            --region "${REGION}" \
            --image-scanning-configuration scanOnPush=true \
            --encryption-configuration encryptionType=AES256
        echo "   ${svc} repository created"
    fi
done

echo ""
echo "All ECR repositories ready!"
echo ""
echo "Repository URLs:"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REGION="${AWS_REGION:-us-east-1}"
for svc in "${SERVICES[@]}"; do
    echo "  - ${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/${svc}"
done
