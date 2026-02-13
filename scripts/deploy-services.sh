#!/bin/bash
#
# FIAP Phase 4 - Deploy Microservices Only
#
# Deploys/updates only the microservices (assumes shared infrastructure already exists)
#
# Usage:
#   ./deploy-services.sh [--service=<name>] [--env=<development|production>]
#
# Examples:
#   ./deploy-services.sh                    # Deploy all services
#   ./deploy-services.sh --service=os       # Deploy OS Service only
#   ./deploy-services.sh --service=billing  # Deploy Billing Service only
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
SERVICE=""
ENVIRONMENT="development"

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --service=*)
      SERVICE="${1#*=}"
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
      echo "Usage: $0 [--service=<os|billing|execution>] [--env=<development|production>]"
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

check_kubectl() {
    log_info "Checking kubectl connection..."
    if ! kubectl cluster-info &> /dev/null; then
        log_error "Cannot connect to Kubernetes cluster. Run:"
        echo "  cd $PROJECT_ROOT/kubernetes-core-infra"
        echo "  ./scripts/configure-kubectl.sh"
        exit 1
    fi
    log_success "kubectl connection verified!"
}

deploy_os_service() {
    log_info "Deploying OS Service (environment: $ENVIRONMENT)..."
    cd "$PROJECT_ROOT/os-service"
    kubectl apply -k "k8s/overlays/$ENVIRONMENT"

    log_info "Waiting for OS Service pods..."
    kubectl wait --for=condition=ready pod \
        -l app=os-service \
        -n "$NAMESPACE" \
        --timeout=300s || log_warning "OS Service pods not ready yet"

    log_success "OS Service deployed!"
}

deploy_billing_service() {
    log_info "Deploying Billing Service (environment: $ENVIRONMENT)..."
    cd "$PROJECT_ROOT/billing-service"
    kubectl apply -k "k8s/overlays/$ENVIRONMENT"

    log_info "Waiting for Billing Service pods..."
    kubectl wait --for=condition=ready pod \
        -l app=billing-service \
        -n "$NAMESPACE" \
        --timeout=300s || log_warning "Billing Service pods not ready yet"

    log_success "Billing Service deployed!"
}

deploy_execution_service() {
    log_info "Deploying Execution Service (environment: $ENVIRONMENT)..."
    cd "$PROJECT_ROOT/execution-service"
    kubectl apply -k "k8s/overlays/$ENVIRONMENT"

    log_info "Waiting for Execution Service pods..."
    kubectl wait --for=condition=ready pod \
        -l app=execution-service \
        -n "$NAMESPACE" \
        --timeout=300s || log_warning "Execution Service pods not ready yet"

    log_success "Execution Service deployed!"
}

show_status() {
    log_info "========================================="
    log_info "  Deployment Status"
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
}

# Main execution
main() {
    log_info "========================================="
    log_info "  FIAP Phase 4 - Deploy Microservices"
    log_info "  Environment: $ENVIRONMENT"
    log_info "========================================="
    echo ""

    START_TIME=$(date +%s)

    check_kubectl

    if [ -z "$SERVICE" ]; then
        log_info "Deploying all microservices..."
        echo ""
        deploy_os_service
        echo ""
        deploy_billing_service
        echo ""
        deploy_execution_service
    else
        case $SERVICE in
            os)        deploy_os_service ;;
            billing)   deploy_billing_service ;;
            execution) deploy_execution_service ;;
            *)
                log_error "Unknown service: $SERVICE"
                echo "Valid services: os, billing, execution"
                exit 1
                ;;
        esac
    fi

    echo ""
    show_status

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
