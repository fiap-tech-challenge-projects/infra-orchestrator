#!/bin/bash
# =============================================================================
# AWS Resource Cleanup Script
# =============================================================================
# Deletes all AWS resources for FIAP Tech Challenge when Terraform fails
# =============================================================================

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Configuration
PROJECT_NAME="fiap-tech-challenge"
REGION="${AWS_REGION:-us-east-1}"
ENVIRONMENT="${1:-staging}"

# =============================================================================
# Functions
# =============================================================================

print_header() {
    echo -e "\n${BLUE}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}  AWS Resource Cleanup - ${ENVIRONMENT}${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}\n"
}

print_step() {
    echo -e "\n${YELLOW}▶ $1${NC}"
}

print_success() {
    echo -e "${GREEN}✓ $1${NC}"
}

print_error() {
    echo -e "${RED}✗ $1${NC}"
}

print_info() {
    echo -e "${BLUE}ℹ $1${NC}"
}

confirm_deletion() {
    echo -e "${RED}WARNING: This will DELETE all resources for environment: ${ENVIRONMENT}${NC}"
    echo -e "${RED}This action CANNOT be undone!${NC}\n"
    read -p "Type 'DELETE' to confirm: " confirmation

    if [ "$confirmation" != "DELETE" ]; then
        echo -e "${YELLOW}Aborted.${NC}"
        exit 0
    fi
}

# =============================================================================
# Cleanup Functions
# =============================================================================

cleanup_eks_cluster() {
    print_step "Cleaning up EKS cluster..."

    local cluster_name="${PROJECT_NAME}-eks-${ENVIRONMENT}"

    # Check if cluster exists
    if aws eks describe-cluster --name "$cluster_name" --region "$REGION" &>/dev/null; then
        print_info "Found EKS cluster: $cluster_name"

        # Delete node groups first
        local nodegroups=$(aws eks list-nodegroups --cluster-name "$cluster_name" --region "$REGION" --query 'nodegroups[*]' --output text 2>/dev/null || echo "")

        if [ -n "$nodegroups" ]; then
            for ng in $nodegroups; do
                print_info "Deleting node group: $ng"
                aws eks delete-nodegroup --cluster-name "$cluster_name" --nodegroup-name "$ng" --region "$REGION" 2>/dev/null || true
            done

            # Wait for node groups to be deleted
            print_info "Waiting for node groups to be deleted..."
            sleep 30
        fi

        # Delete cluster
        print_info "Deleting EKS cluster..."
        aws eks delete-cluster --name "$cluster_name" --region "$REGION" 2>/dev/null || true

        # Wait for cluster deletion
        print_info "Waiting for cluster deletion (this may take a few minutes)..."
        aws eks wait cluster-deleted --name "$cluster_name" --region "$REGION" 2>/dev/null || true

        print_success "EKS cluster deleted"
    else
        print_info "No EKS cluster found"
    fi
}

cleanup_rds() {
    print_step "Cleaning up RDS instances..."

    local db_identifier="${PROJECT_NAME}-db-${ENVIRONMENT}"

    # Check if RDS exists
    if aws rds describe-db-instances --db-instance-identifier "$db_identifier" --region "$REGION" &>/dev/null; then
        print_info "Found RDS instance: $db_identifier"

        # Delete without final snapshot (since it's staging/dev)
        aws rds delete-db-instance \
            --db-instance-identifier "$db_identifier" \
            --skip-final-snapshot \
            --region "$REGION" 2>/dev/null || true

        print_info "Waiting for RDS deletion (this may take a few minutes)..."
        aws rds wait db-instance-deleted --db-instance-identifier "$db_identifier" --region "$REGION" 2>/dev/null || true

        print_success "RDS instance deleted"
    else
        print_info "No RDS instance found"
    fi
}

cleanup_lambda() {
    print_step "Cleaning up Lambda functions..."

    # List and delete Lambda functions with project tag
    local functions=$(aws lambda list-functions --region "$REGION" --query "Functions[?starts_with(FunctionName, '${PROJECT_NAME}')].FunctionName" --output text)

    if [ -n "$functions" ]; then
        for func in $functions; do
            print_info "Deleting Lambda function: $func"
            aws lambda delete-function --function-name "$func" --region "$REGION" 2>/dev/null || true
        done
        print_success "Lambda functions deleted"
    else
        print_info "No Lambda functions found"
    fi
}

cleanup_vpc() {
    print_step "Cleaning up VPC and network resources..."

    # Find VPC by project tag
    local vpc_id=$(aws ec2 describe-vpcs \
        --filters "Name=tag:Project,Values=${PROJECT_NAME}" "Name=tag:Environment,Values=${ENVIRONMENT}" \
        --region "$REGION" \
        --query 'Vpcs[0].VpcId' \
        --output text 2>/dev/null)

    if [ "$vpc_id" == "None" ] || [ -z "$vpc_id" ]; then
        print_info "No VPC found"
        return
    fi

    print_info "Found VPC: $vpc_id"

    # 1. Delete NAT Gateways
    print_info "Deleting NAT Gateways..."
    local nat_gateways=$(aws ec2 describe-nat-gateways \
        --filter "Name=vpc-id,Values=$vpc_id" "Name=state,Values=available" \
        --region "$REGION" \
        --query 'NatGateways[*].NatGatewayId' \
        --output text)

    for nat in $nat_gateways; do
        aws ec2 delete-nat-gateway --nat-gateway-id "$nat" --region "$REGION" 2>/dev/null || true
    done

    if [ -n "$nat_gateways" ]; then
        print_info "Waiting for NAT Gateways to be deleted..."
        sleep 60
    fi

    # 2. Release Elastic IPs
    print_info "Releasing Elastic IPs..."
    local eips=$(aws ec2 describe-addresses \
        --filters "Name=domain,Values=vpc" \
        --region "$REGION" \
        --query "Addresses[?Tags[?Key=='Project' && Value=='${PROJECT_NAME}']].AllocationId" \
        --output text)

    for eip in $eips; do
        aws ec2 release-address --allocation-id "$eip" --region "$REGION" 2>/dev/null || true
    done

    # 3. Delete VPC Endpoints
    print_info "Deleting VPC Endpoints..."
    local endpoints=$(aws ec2 describe-vpc-endpoints \
        --filters "Name=vpc-id,Values=$vpc_id" \
        --region "$REGION" \
        --query 'VpcEndpoints[*].VpcEndpointId' \
        --output text)

    for endpoint in $endpoints; do
        aws ec2 delete-vpc-endpoints --vpc-endpoint-ids "$endpoint" --region "$REGION" 2>/dev/null || true
    done

    # 4. Delete Security Group Rules (to avoid dependencies)
    print_info "Removing Security Group rules..."
    local sgs=$(aws ec2 describe-security-groups \
        --filters "Name=vpc-id,Values=$vpc_id" \
        --region "$REGION" \
        --query 'SecurityGroups[?GroupName!=`default`].GroupId' \
        --output text)

    for sg in $sgs; do
        # Revoke ingress rules
        aws ec2 describe-security-groups --group-ids "$sg" --region "$REGION" \
            --query 'SecurityGroups[0].IpPermissions' --output json | \
            jq -r 'if . != null and . != [] then . else empty end' | \
            xargs -I {} aws ec2 revoke-security-group-ingress --group-id "$sg" --ip-permissions '{}' --region "$REGION" 2>/dev/null || true

        # Revoke egress rules
        aws ec2 describe-security-groups --group-ids "$sg" --region "$REGION" \
            --query 'SecurityGroups[0].IpPermissionsEgress' --output json | \
            jq -r 'if . != null and . != [] then . else empty end' | \
            xargs -I {} aws ec2 revoke-security-group-egress --group-id "$sg" --ip-permissions '{}' --region "$REGION" 2>/dev/null || true
    done

    # 5. Delete Network Interfaces
    print_info "Deleting Network Interfaces..."
    local enis=$(aws ec2 describe-network-interfaces \
        --filters "Name=vpc-id,Values=$vpc_id" \
        --region "$REGION" \
        --query 'NetworkInterfaces[*].NetworkInterfaceId' \
        --output text)

    for eni in $enis; do
        aws ec2 delete-network-interface --network-interface-id "$eni" --region "$REGION" 2>/dev/null || true
    done

    # 6. Delete Security Groups (non-default)
    print_info "Deleting Security Groups..."
    for sg in $sgs; do
        aws ec2 delete-security-group --group-id "$sg" --region "$REGION" 2>/dev/null || true
    done

    # 7. Detach and Delete Internet Gateways
    print_info "Deleting Internet Gateways..."
    local igws=$(aws ec2 describe-internet-gateways \
        --filters "Name=attachment.vpc-id,Values=$vpc_id" \
        --region "$REGION" \
        --query 'InternetGateways[*].InternetGatewayId' \
        --output text)

    for igw in $igws; do
        aws ec2 detach-internet-gateway --internet-gateway-id "$igw" --vpc-id "$vpc_id" --region "$REGION" 2>/dev/null || true
        aws ec2 delete-internet-gateway --internet-gateway-id "$igw" --region "$REGION" 2>/dev/null || true
    done

    # 8. Delete Subnets
    print_info "Deleting Subnets..."
    local subnets=$(aws ec2 describe-subnets \
        --filters "Name=vpc-id,Values=$vpc_id" \
        --region "$REGION" \
        --query 'Subnets[*].SubnetId' \
        --output text)

    for subnet in $subnets; do
        aws ec2 delete-subnet --subnet-id "$subnet" --region "$REGION" 2>/dev/null || true
    done

    # 9. Delete Route Tables (non-main)
    print_info "Deleting Route Tables..."
    local route_tables=$(aws ec2 describe-route-tables \
        --filters "Name=vpc-id,Values=$vpc_id" \
        --region "$REGION" \
        --query 'RouteTables[?Associations[0].Main==`false`].RouteTableId' \
        --output text)

    for rt in $route_tables; do
        # Disassociate first
        local associations=$(aws ec2 describe-route-tables --route-table-ids "$rt" --region "$REGION" \
            --query 'RouteTables[0].Associations[*].RouteTableAssociationId' --output text)
        for assoc in $associations; do
            aws ec2 disassociate-route-table --association-id "$assoc" --region "$REGION" 2>/dev/null || true
        done

        aws ec2 delete-route-table --route-table-id "$rt" --region "$REGION" 2>/dev/null || true
    done

    # 10. Finally, delete VPC
    print_info "Deleting VPC..."
    aws ec2 delete-vpc --vpc-id "$vpc_id" --region "$REGION" 2>/dev/null || true

    print_success "VPC and network resources deleted"
}

cleanup_secrets() {
    print_step "Cleaning up Secrets Manager secrets..."

    local secrets=$(aws secretsmanager list-secrets \
        --region "$REGION" \
        --query "SecretList[?starts_with(Name, '${PROJECT_NAME}/${ENVIRONMENT}')].Name" \
        --output text)

    if [ -n "$secrets" ]; then
        for secret in $secrets; do
            print_info "Deleting secret: $secret"
            aws secretsmanager delete-secret \
                --secret-id "$secret" \
                --force-delete-without-recovery \
                --region "$REGION" 2>/dev/null || true
        done
        print_success "Secrets deleted"
    else
        print_info "No secrets found"
    fi
}

# =============================================================================
# Main
# =============================================================================

print_header
confirm_deletion

echo -e "\n${YELLOW}Starting cleanup for environment: ${ENVIRONMENT}${NC}\n"

# Cleanup in correct order (reverse of creation)
cleanup_lambda
cleanup_rds
cleanup_eks_cluster
cleanup_vpc
cleanup_secrets

echo -e "\n${GREEN}═══════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  Cleanup completed!${NC}"
echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}\n"

echo -e "${BLUE}Next steps:${NC}"
echo -e "1. Run Terraform destroy to clean up state files"
echo -e "2. Or run the deployment again with fresh state\n"
