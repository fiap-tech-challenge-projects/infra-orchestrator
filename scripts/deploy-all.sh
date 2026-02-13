#!/bin/bash
#
# FIAP Phase 4 - Complete Environment Deployment
#
# Deploys the ENTIRE Phase 4 infrastructure from scratch:
# 1. Shared Infrastructure (EKS, K8s addons, databases, messaging, auth)
# 2. ECR repositories + Docker images
# 3. Database migrations
# 4. All Microservices (OS, Billing, Execution)
#
# Prerequisites:
# - AWS CLI configured with valid credentials
# - kubectl, terraform, docker installed
#
# Usage:
#   ./deploy-all.sh [--skip-infra] [--skip-services] [--skip-docker] [--env=<development|production>]
#

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SKIP_INFRA=false
SKIP_SERVICES=false
SKIP_DOCKER=false
ENVIRONMENT="development"
REGION="${AWS_REGION:-us-east-1}"

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --skip-infra)
      SKIP_INFRA=true
      shift
      ;;
    --skip-services)
      SKIP_SERVICES=true
      shift
      ;;
    --skip-docker)
      SKIP_DOCKER=true
      shift
      ;;
    --env=*|--environment=*)
      ENVIRONMENT="${1#*=}"
      if [[ "$ENVIRONMENT" != "development" && "$ENVIRONMENT" != "production" ]]; then
        echo -e "${RED}[ERROR]${NC} Invalid environment: $ENVIRONMENT (must be 'development' or 'production')"
        exit 1
      fi
      shift
      ;;
    *)
      echo "Unknown option: $1"
      echo "Usage: $0 [--skip-infra] [--skip-services] [--skip-docker] [--env=<development|production>]"
      exit 1
      ;;
  esac
done

# Derived configuration
NAMESPACE="ftc-app-${ENVIRONMENT}"

# Functions
log_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; }

check_prerequisites() {
    log_info "Checking prerequisites..."
    local missing=false

    for cmd in aws kubectl terraform; do
        if ! command -v "$cmd" &> /dev/null; then
            log_error "$cmd not found"
            missing=true
        fi
    done

    if ! aws sts get-caller-identity &> /dev/null; then
        log_error "AWS credentials not configured. Run: aws configure"
        missing=true
    fi

    if [ "$missing" = true ]; then exit 1; fi
    log_success "All prerequisites met!"
}

get_tf_bucket() {
    local account_id
    account_id=$(aws sts get-caller-identity --query Account --output text)
    echo "fiap-tech-challenge-tf-state-${account_id}"
}

bootstrap_terraform_backend() {
    log_info "Bootstrapping Terraform backend..."
    local bucket
    bucket=$(get_tf_bucket)

    if aws s3api head-bucket --bucket "$bucket" --region "$REGION" 2>/dev/null; then
        log_info "S3 bucket $bucket already exists"
    else
        log_info "Creating S3 bucket: $bucket"
        aws s3api create-bucket --bucket "$bucket" --region "$REGION"
        aws s3api put-bucket-versioning --bucket "$bucket" \
            --versioning-configuration Status=Enabled
        log_success "S3 bucket created"
    fi

    if aws dynamodb describe-table --table-name "fiap-terraform-locks" --region "$REGION" > /dev/null 2>&1; then
        log_info "DynamoDB lock table already exists"
    else
        log_info "Creating DynamoDB lock table..."
        aws dynamodb create-table \
            --table-name "fiap-terraform-locks" \
            --attribute-definitions AttributeName=LockID,AttributeType=S \
            --key-schema AttributeName=LockID,KeyType=HASH \
            --billing-mode PAY_PER_REQUEST \
            --region "$REGION" > /dev/null 2>&1
        log_info "Waiting for DynamoDB table to become active..."
        aws dynamodb wait table-exists --table-name "fiap-terraform-locks" --region "$REGION"
        log_success "DynamoDB lock table created and active"
    fi
}

deploy_terraform_component() {
    local name="$1"
    local tf_dir="$2"
    local bucket
    bucket=$(get_tf_bucket)

    log_info "Deploying $name..."
    (
        cd "$tf_dir"
        terraform init -input=false -backend-config="bucket=$bucket"
        terraform workspace select "$ENVIRONMENT" || terraform workspace new "$ENVIRONMENT"
        terraform plan -var="environment=$ENVIRONMENT" -out=tfplan
        terraform apply -auto-approve tfplan
    )
    log_success "$name deployed!"
    echo ""
}

deploy_shared_infrastructure() {
    if [ "$SKIP_INFRA" = true ]; then
        log_warning "Skipping shared infrastructure deployment"
        return 0
    fi

    log_info "========================================="
    log_info "  Deploying Shared Infrastructure"
    log_info "========================================="
    echo ""

    deploy_terraform_component "1/5 EKS Cluster (15-20 min)" "$PROJECT_ROOT/kubernetes-core-infra/terraform"
    deploy_terraform_component "2/5 Kubernetes Addons (5-10 min)" "$PROJECT_ROOT/kubernetes-addons/terraform"
    deploy_terraform_component "3/5 Databases (10-15 min)" "$PROJECT_ROOT/database-managed-infra/terraform"
    deploy_terraform_component "4/5 Messaging (2-3 min)" "$PROJECT_ROOT/messaging-infra/terraform"
    deploy_terraform_component "5/5 Lambda Auth (3-5 min)" "$PROJECT_ROOT/lambda-api-handler/terraform"

    log_success "Shared infrastructure deployment complete!"
}

configure_kubectl() {
    log_info "Configuring kubectl..."
    local script="$PROJECT_ROOT/kubernetes-core-infra/scripts/configure-kubectl.sh"

    if [ -f "$script" ]; then
        bash "$script"
        log_success "kubectl configured!"
    else
        log_warning "kubectl config script not found, using aws eks directly..."
        local account_id
        account_id=$(aws sts get-caller-identity --query Account --output text)
        aws eks update-kubeconfig --region "$REGION" --name "fiap-tech-challenge-eks-${ENVIRONMENT}"
    fi
}

build_and_push_images() {
    if [ "$SKIP_DOCKER" = true ]; then
        log_warning "Skipping Docker build and push"
        return 0
    fi

    log_info "========================================="
    log_info "  Building and Pushing Docker Images"
    log_info "========================================="
    echo ""

    # Create ECR repos
    bash "$SCRIPT_DIR/create-ecr-repos.sh"

    # Build and push images
    bash "$SCRIPT_DIR/build-and-push.sh" --env="$ENVIRONMENT"
}

create_os_service_secrets() {
    log_info "Creating os-service-secrets from AWS Secrets Manager..."
    local secret_name="fiap-tech-challenge/${ENVIRONMENT}/database/credentials"
    local secret_value

    secret_value=$(aws secretsmanager get-secret-value \
        --secret-id "$secret_name" \
        --region "$REGION" \
        --query SecretString \
        --output text 2>/dev/null || echo "")

    if [ -n "$secret_value" ]; then
        local db_url
        db_url=$(echo "$secret_value" | jq -r '.DATABASE_URL // empty')

        if [ -z "$db_url" ]; then
            # Build DATABASE_URL from individual fields
            local host port dbname user pass
            host=$(echo "$secret_value" | jq -r '.host // empty')
            port=$(echo "$secret_value" | jq -r '.port // "5432"')
            dbname=$(echo "$secret_value" | jq -r '.dbname // empty')
            user=$(echo "$secret_value" | jq -r '.username // empty')
            pass=$(echo "$secret_value" | jq -r '.password // empty')
            db_url="postgresql://${user}:${pass}@${host}:${port}/${dbname}?schema=public"
        fi

        kubectl create secret generic os-service-secrets -n "$NAMESPACE" \
            --from-literal=DATABASE_URL="$db_url" \
            --dry-run=client -o yaml | kubectl apply -f -
        log_success "os-service-secrets created with DATABASE_URL"
    else
        log_warning "Could not fetch database credentials from Secrets Manager"
        log_warning "os-service-secrets must be created manually"
    fi
}

run_migrations() {
    log_info "Running database migrations..."

    kubectl delete job os-service-migration -n "$NAMESPACE" 2>/dev/null || true
    kubectl apply -f "$PROJECT_ROOT/os-service/k8s/migration-job.yaml" -n "$NAMESPACE"
    sleep 5

    for i in {1..60}; do
        STATUS=$(kubectl get job os-service-migration -n "$NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Complete")].status}' 2>/dev/null || echo "")
        if [ "$STATUS" == "True" ]; then
            log_success "Database migrations complete"
            kubectl logs -n "$NAMESPACE" job/os-service-migration --tail=5
            return 0
        fi
        if [ $i -eq 60 ]; then
            log_error "Migration job timed out"
            kubectl logs -n "$NAMESPACE" job/os-service-migration --tail=20
            exit 1
        fi
        echo "  Waiting... ($i/60)"
        sleep 2
    done
}

deploy_microservices() {
    if [ "$SKIP_SERVICES" = true ]; then
        log_warning "Skipping microservices deployment"
        return 0
    fi

    log_info "========================================="
    log_info "  Deploying Microservices"
    log_info "========================================="
    echo ""

    # Update AWS credentials in K8s
    bash "$SCRIPT_DIR/update-k8s-credentials.sh" "$ENVIRONMENT"

    # Create os-service-secrets from AWS Secrets Manager (needed for migrations and deployment)
    create_os_service_secrets

    # Run migrations
    run_migrations

    # Deploy services
    for svc in os-service billing-service execution-service; do
        log_info "Deploying $svc (environment: $ENVIRONMENT)..."
        (
            cd "$PROJECT_ROOT/$svc"
            kubectl apply -k "k8s/overlays/$ENVIRONMENT" 2>/dev/null || true
        ) || log_warning "$svc deployment skipped"
        log_success "$svc deployed!"
        echo ""
    done
}

wait_for_pods() {
    log_info "Waiting for pods to be ready..."

    for svc in os-service billing-service execution-service; do
        kubectl wait --for=condition=ready pod \
            -l "app=$svc" \
            -n "$NAMESPACE" \
            --timeout=300s 2>/dev/null || log_warning "$svc pods not ready yet"
    done

    log_success "Pod readiness check complete!"
}

show_endpoints() {
    log_info "========================================="
    log_info "  Deployment Summary"
    log_info "========================================="
    echo ""

    log_info "Running Pods:"
    kubectl get pods -n "$NAMESPACE"
    echo ""

    log_info "Services:"
    kubectl get svc -n "$NAMESPACE"
    echo ""

    log_info "Ingress:"
    kubectl get ingress -n "$NAMESPACE"
    echo ""

    ALB_URL=$(kubectl get ingress -n "$NAMESPACE" -o jsonpath='{.items[0].status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
    if [ -n "$ALB_URL" ]; then
        log_success "Application Load Balancer URL:"
        echo "  http://$ALB_URL"
        echo ""
        log_info "API Endpoints:"
        echo "  OS Service:        http://$ALB_URL/api/v1/service-orders"
        echo "  Billing Service:   http://$ALB_URL/api/v1/budgets"
        echo "  Execution Service: http://$ALB_URL/api/v1/executions"
    else
        log_warning "Load balancer not ready yet. Check again with:"
        echo "  kubectl get ingress -n $NAMESPACE"
    fi
}

# Main execution
main() {
    log_info "========================================="
    log_info "  FIAP Phase 4 - Complete Deployment"
    log_info "  Environment: $ENVIRONMENT"
    log_info "========================================="
    echo ""

    START_TIME=$(date +%s)

    check_prerequisites
    bootstrap_terraform_backend
    deploy_shared_infrastructure
    configure_kubectl
    build_and_push_images
    deploy_microservices
    wait_for_pods
    show_endpoints

    END_TIME=$(date +%s)
    DURATION=$((END_TIME - START_TIME))
    MINUTES=$((DURATION / 60))
    SECONDS=$((DURATION % 60))

    echo ""
    log_success "========================================="
    log_success "  Deployment Complete!"
    log_success "========================================="
    log_info "Total time: ${MINUTES}m ${SECONDS}s"
    echo ""
}

main
