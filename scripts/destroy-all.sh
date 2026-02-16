#!/bin/bash
#
# FIAP Phase 4 - Complete Environment Cleanup
#
# Destroys the ENTIRE Phase 4 infrastructure:
# 1. All Microservices (via kubectl)
# 2. Shared Infrastructure (via Terraform, with AWS CLI fallback)
# 3. Orphaned resources (via aggressive AWS CLI cleanup)
# 4. S3 state bucket and DynamoDB locks
#
# WARNING: This will DELETE ALL DATA!
#
# Usage:
#   ./destroy-all.sh [--skip-services] [--skip-shared-infra] [--force] [--env=<development|production>]
#

set -e

export AWS_PAGER=""

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PROJECT_NAME="fiap-tech-challenge"
REGION="${AWS_REGION:-us-east-1}"
SKIP_SERVICES=false
SKIP_SHARED_INFRA=false
FORCE=false
ENVIRONMENT="development"
ACCOUNT_ID=""

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --skip-services)
      SKIP_SERVICES=true
      shift
      ;;
    --skip-shared-infra)
      SKIP_SHARED_INFRA=true
      shift
      ;;
    --force)
      FORCE=true
      shift
      ;;
    --env=*|--environment=*)
      ENVIRONMENT="${1#*=}"
      if [[ "$ENVIRONMENT" != "development" && "$ENVIRONMENT" != "production" ]]; then
        echo "Invalid environment: $ENVIRONMENT (must be 'development' or 'production')"
        exit 1
      fi
      shift
      ;;
    *)
      echo "Unknown option: $1"
      echo "Usage: $0 [--skip-services] [--skip-shared-infra] [--force] [--env=<development|production>]"
      exit 1
      ;;
  esac
done

# Functions
log_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[OK]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error()   { echo -e "${RED}[ERR]${NC} $1"; }

confirm_destruction() {
    if [ "$FORCE" = true ]; then return 0; fi

    echo ""
    log_warning "WARNING: This will DESTROY ALL Phase 4 infrastructure!"
    log_warning "This includes:"
    echo "  - All Kubernetes deployments and namespaces"
    echo "  - EKS cluster and node groups"
    echo "  - All databases (RDS, DynamoDB, DocumentDB)"
    echo "  - All messaging infrastructure (EventBridge, SQS)"
    echo "  - Lambda functions and API Gateway"
    echo "  - Load Balancers, NAT Gateways, VPCs"
    echo "  - ECR repositories, IAM roles"
    echo "  - S3 state bucket and DynamoDB locks"
    echo "  - ALL DATA WILL BE LOST!"
    echo ""
    read -p "Type 'DELETE' to confirm: " confirm_delete
    if [ "$confirm_delete" != "DELETE" ]; then
        log_info "Cleanup cancelled."
        exit 0
    fi
    log_info "Proceeding with cleanup..."
}

check_prerequisites() {
    log_info "Checking prerequisites..."

    if ! command -v aws &> /dev/null; then
        log_error "AWS CLI not found."
        exit 1
    fi

    ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null)
    if [ -z "$ACCOUNT_ID" ]; then
        log_error "AWS credentials not configured."
        exit 1
    fi
    log_info "AWS Account: $ACCOUNT_ID"
}

configure_kubectl() {
    local clusters
    clusters=$(aws eks list-clusters --region "$REGION" --query 'clusters[*]' --output text 2>/dev/null)
    if [ -z "$clusters" ]; then
        log_info "No EKS clusters found"
        return 0
    fi

    for cluster in $clusters; do
        log_info "Configuring kubectl for: $cluster"
        if aws eks update-kubeconfig --region "$REGION" --name "$cluster" > /dev/null 2>&1; then
            log_success "kubectl configured for $cluster"
            return 0
        fi
    done

    log_warning "Could not configure kubectl"
    return 1
}

destroy_microservices() {
    if [ "$SKIP_SERVICES" = true ]; then
        log_warning "Skipping microservices destruction"
        return 0
    fi

    log_info "========================================="
    log_info "  Phase 1: Destroying Microservices"
    log_info "========================================="
    echo ""

    if command -v kubectl &> /dev/null; then
        for ns in ftc-app-development ftc-app-production signoz; do
            log_info "Deleting namespace: $ns"
            kubectl delete namespace "$ns" --ignore-not-found=true --timeout=60s 2>/dev/null || true
        done
    fi

    log_success "Microservices destroyed!"
    echo ""
}

destroy_terraform_component() {
    local name="$1"
    local tf_dir="$2"

    if [ ! -d "$tf_dir" ]; then
        log_warning "Directory not found: $tf_dir - skipping"
        return 0
    fi

    log_info "Destroying $name via Terraform..."

    if command -v terraform &> /dev/null; then
        local bucket="${PROJECT_NAME}-tf-state-${ACCOUNT_ID}"
        local tf_result=0

        (
            cd "$tf_dir"
            if terraform init -reconfigure -input=false -backend-config="bucket=$bucket" > /dev/null 2>&1; then
                terraform workspace select "$ENVIRONMENT" 2>/dev/null || terraform workspace new "$ENVIRONMENT" 2>/dev/null || true
                terraform destroy -var="environment=$ENVIRONMENT" -auto-approve -input=false 2>&1
            else
                echo "INIT_FAILED" >&2
                exit 1
            fi
        ) || tf_result=$?

        if [ $tf_result -eq 0 ]; then
            log_success "$name destroyed via Terraform"
            return 0
        else
            log_warning "$name Terraform destroy failed - will use AWS CLI fallback"
        fi
    fi

    return 1
}

destroy_shared_infrastructure() {
    if [ "$SKIP_SHARED_INFRA" = true ]; then
        log_warning "Skipping shared infrastructure destruction"
        return 0
    fi

    log_info "========================================="
    log_info "  Phase 2: Destroying Shared Infrastructure"
    log_info "  (in reverse order)"
    log_info "========================================="
    echo ""

    destroy_terraform_component "Lambda Auth" "$PROJECT_ROOT/lambda-api-handler/terraform" || true
    destroy_terraform_component "Messaging" "$PROJECT_ROOT/messaging-infra/terraform" || true
    destroy_terraform_component "Databases" "$PROJECT_ROOT/database-managed-infra/terraform" || true
    destroy_terraform_component "Kubernetes Addons" "$PROJECT_ROOT/kubernetes-addons/terraform" || true
    destroy_terraform_component "EKS Cluster" "$PROJECT_ROOT/kubernetes-core-infra/terraform" || true

    log_success "Terraform destroy phase complete!"
    echo ""
}

aggressive_aws_cleanup() {
    log_info "========================================="
    log_info "  Phase 3: Aggressive AWS CLI Cleanup"
    log_info "========================================="
    echo ""

    local cleanup_script="$SCRIPT_DIR/cleanup-aws-resources.sh"
    if [ -f "$cleanup_script" ]; then
        log_info "Running aggressive cleanup script..."
        chmod +x "$cleanup_script"
        FORCE="true" bash "$cleanup_script" "$ENVIRONMENT" --force || {
            log_warning "Aggressive cleanup had some failures - continuing..."
        }
    else
        log_error "Aggressive cleanup script not found at: $cleanup_script"
        exit 1
    fi
}

cleanup_state_backend() {
    log_info "========================================="
    log_info "  Phase 4: Cleanup State Backend"
    log_info "========================================="
    echo ""

    local bucket_name="${PROJECT_NAME}-tf-state-${ACCOUNT_ID}"
    if aws s3api head-bucket --bucket "$bucket_name" --region "$REGION" 2>/dev/null; then
        log_info "Emptying S3 bucket: $bucket_name (including versions)..."

        python3 -c "
import json, subprocess, sys

bucket = '$bucket_name'
region = '$REGION'

result = subprocess.run(
    ['aws', 's3api', 'list-object-versions', '--bucket', bucket, '--region', region, '--output', 'json'],
    capture_output=True, text=True
)

if result.returncode != 0:
    sys.exit(0)

data = json.loads(result.stdout)
objects = []
for v in data.get('Versions', []):
    objects.append({'Key': v['Key'], 'VersionId': v['VersionId']})
for dm in data.get('DeleteMarkers', []):
    objects.append({'Key': dm['Key'], 'VersionId': dm['VersionId']})

for i in range(0, len(objects), 1000):
    batch = objects[i:i+1000]
    payload = json.dumps({'Objects': batch, 'Quiet': True})
    subprocess.run(
        ['aws', 's3api', 'delete-objects', '--bucket', bucket, '--delete', payload, '--region', region],
        capture_output=True
    )
    print(f'  Deleted {len(batch)} objects/versions')
" 2>/dev/null

        aws s3 rb "s3://$bucket_name" --region "$REGION" 2>/dev/null && \
            log_success "S3 state bucket deleted" || \
            log_warning "Failed to delete S3 bucket"
    else
        log_info "No S3 state bucket found"
    fi

    if aws dynamodb describe-table --table-name "fiap-terraform-locks" --region "$REGION" > /dev/null 2>&1; then
        log_info "Deleting DynamoDB lock table..."
        aws dynamodb delete-table --table-name "fiap-terraform-locks" --region "$REGION" > /dev/null 2>&1
        log_success "DynamoDB lock table deleted"
    else
        log_info "No DynamoDB lock table found"
    fi
}

validate_cleanup() {
    log_info "========================================="
    log_info "  Phase 5: Validation"
    log_info "========================================="
    echo ""

    local issues=0

    check() {
        local name="$1"
        local result="$2"
        if [ -n "$result" ] && [ "$result" != "[]" ] && [ "$result" != "None" ]; then
            log_error "$name: STILL EXISTS"
            issues=$((issues + 1))
        else
            log_success "$name: clean"
        fi
    }

    check "EKS" "$(aws eks list-clusters --region "$REGION" --query 'clusters[*]' --output text 2>/dev/null)"
    check "RDS" "$(aws rds describe-db-instances --region "$REGION" --query 'DBInstances[*].DBInstanceIdentifier' --output text 2>/dev/null)"
    check "VPCs" "$(aws ec2 describe-vpcs --region "$REGION" --filters 'Name=is-default,Values=false' --query 'Vpcs[*].VpcId' --output text 2>/dev/null)"
    check "LBs" "$(aws elbv2 describe-load-balancers --region "$REGION" --query 'LoadBalancers[*].LoadBalancerName' --output text 2>/dev/null)"
    check "Lambda" "$(aws lambda list-functions --region "$REGION" --query 'Functions[*].FunctionName' --output text 2>/dev/null)"
    check "ECR" "$(aws ecr describe-repositories --region "$REGION" --query 'repositories[*].repositoryName' --output text 2>/dev/null)"

    echo ""
    if [ $issues -eq 0 ]; then
        log_success "ALL RESOURCES CLEANED UP!"
    else
        log_error "$issues resource type(s) still have remaining items"
    fi
}

cleanup_local_state() {
    log_info "Cleaning up local state..."
    kubectl config unset current-context 2>/dev/null || true
    for ctx in $(kubectl config get-contexts -o name 2>/dev/null | grep -iE "fiap|eks" || true); do
        kubectl config delete-context "$ctx" 2>/dev/null || true
    done
    for cluster in $(kubectl config get-clusters 2>/dev/null | grep -iE "fiap|eks" || true); do
        kubectl config delete-cluster "$cluster" 2>/dev/null || true
    done
    log_success "Local state cleaned up!"
}

# Main execution
main() {
    log_info "========================================="
    log_info "  FIAP Phase 4 - Complete Cleanup"
    log_info "  Environment: $ENVIRONMENT"
    log_info "========================================="
    echo ""

    START_TIME=$(date +%s)

    check_prerequisites
    confirm_destruction

    configure_kubectl || true
    destroy_microservices
    destroy_shared_infrastructure
    aggressive_aws_cleanup
    cleanup_state_backend
    validate_cleanup
    cleanup_local_state

    END_TIME=$(date +%s)
    DURATION=$((END_TIME - START_TIME))
    MINUTES=$((DURATION / 60))
    SECONDS=$((DURATION % 60))

    echo ""
    log_success "========================================="
    log_success "  Cleanup Complete!"
    log_success "========================================="
    log_info "Total time: ${MINUTES}m ${SECONDS}s"
    log_info "All Phase 4 infrastructure has been destroyed."
    echo ""
}

main
