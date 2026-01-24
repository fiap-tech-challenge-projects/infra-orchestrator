#!/bin/bash
# =============================================================================
# AWS Resource Cleanup Script - AGGRESSIVE MODE
# =============================================================================
# Forcefully deletes all AWS resources for FIAP Tech Challenge
# =============================================================================

# Disable AWS CLI pager
export AWS_PAGER=""

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
    echo -e "${BLUE}  AWS Resource Cleanup (AGGRESSIVE) - ${ENVIRONMENT}${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}\n"
}

print_step() {
    echo -e "\n${YELLOW}▶ $1${NC}"
}

print_success() {
    echo -e "${GREEN}✓ $1${NC}"
}

print_info() {
    echo -e "${BLUE}  $1${NC}"
}

confirm_deletion() {
    echo -e "${RED}WARNING: This will FORCEFULLY DELETE all resources for: ${ENVIRONMENT}${NC}"
    echo -e "${RED}This action CANNOT be undone!${NC}\n"
    read -p "Type 'DELETE' to confirm: " confirmation

    if [ "$confirmation" != "DELETE" ]; then
        echo -e "${YELLOW}Aborted.${NC}"
        exit 0
    fi
}

# Retry function
retry() {
    local max_attempts=3
    local attempt=1
    local cmd="$@"

    while [ $attempt -le $max_attempts ]; do
        if eval "$cmd"; then
            return 0
        fi
        attempt=$((attempt + 1))
        [ $attempt -le $max_attempts ] && sleep 2
    done
    return 1
}

# =============================================================================
# Cleanup Functions
# =============================================================================

cleanup_eks_cluster() {
    print_step "Cleaning up EKS cluster..."

    local cluster_name="${PROJECT_NAME}-eks-${ENVIRONMENT}"

    if aws eks describe-cluster --name "$cluster_name" --region "$REGION" &>/dev/null; then
        print_info "Found EKS cluster: $cluster_name"

        # Delete node groups
        local nodegroups=$(aws eks list-nodegroups --cluster-name "$cluster_name" --region "$REGION" --query 'nodegroups[*]' --output text 2>/dev/null || echo "")

        if [ -n "$nodegroups" ]; then
            for ng in $nodegroups; do
                print_info "Deleting node group: $ng"
                aws eks delete-nodegroup --cluster-name "$cluster_name" --nodegroup-name "$ng" --region "$REGION" 2>/dev/null || true
            done
            print_info "Waiting 60s for node groups..."
            sleep 60
        fi

        # Delete cluster
        print_info "Deleting EKS cluster..."
        aws eks delete-cluster --name "$cluster_name" --region "$REGION" 2>/dev/null || true

        print_info "Waiting for cluster deletion..."
        aws eks wait cluster-deleted --name "$cluster_name" --region "$REGION" 2>/dev/null || true

        print_success "EKS cluster deleted"
    else
        print_info "No EKS cluster found"
    fi
}

cleanup_rds() {
    print_step "Cleaning up RDS instances..."

    local db_identifier="${PROJECT_NAME}-db-${ENVIRONMENT}"

    if aws rds describe-db-instances --db-instance-identifier "$db_identifier" --region "$REGION" &>/dev/null; then
        print_info "Found RDS: $db_identifier"

        aws rds delete-db-instance \
            --db-instance-identifier "$db_identifier" \
            --skip-final-snapshot \
            --region "$REGION" 2>/dev/null || true

        print_info "Waiting for RDS deletion..."
        aws rds wait db-instance-deleted --db-instance-identifier "$db_identifier" --region "$REGION" 2>/dev/null || true

        print_success "RDS deleted"
    else
        print_info "No RDS found"
    fi
}

cleanup_lambda() {
    print_step "Cleaning up Lambda functions..."

    local functions=$(aws lambda list-functions --region "$REGION" --query "Functions[?starts_with(FunctionName, '${PROJECT_NAME}')].FunctionName" --output text)

    if [ -n "$functions" ]; then
        for func in $functions; do
            print_info "Deleting: $func"
            aws lambda delete-function --function-name "$func" --region "$REGION" 2>/dev/null || true
        done
        print_success "Lambdas deleted"
    else
        print_info "No Lambdas found"
    fi
}

cleanup_vpc_aggressive() {
    print_step "AGGRESSIVE VPC cleanup..."

    # Find all VPCs with project tag
    local vpc_ids=$(aws ec2 describe-vpcs \
        --filters "Name=tag:Project,Values=${PROJECT_NAME}" \
        --region "$REGION" \
        --query 'Vpcs[*].VpcId' \
        --output text 2>/dev/null)

    if [ -z "$vpc_ids" ]; then
        print_info "No VPCs found"
        return
    fi

    for vpc_id in $vpc_ids; do
        print_info "Processing VPC: $vpc_id"

        # 1. NAT Gateways (wait for deletion)
        print_info "  Deleting NAT Gateways..."
        local nats=$(aws ec2 describe-nat-gateways --filter "Name=vpc-id,Values=$vpc_id" --region "$REGION" --query 'NatGateways[*].NatGatewayId' --output text)
        for nat in $nats; do
            aws ec2 delete-nat-gateway --nat-gateway-id "$nat" --region "$REGION" 2>/dev/null || true
        done
        [ -n "$nats" ] && sleep 90

        # 2. Elastic IPs
        print_info "  Releasing Elastic IPs..."
        local eips=$(aws ec2 describe-addresses --filters "Name=domain,Values=vpc" --region "$REGION" --query 'Addresses[*].AllocationId' --output text)
        for eip in $eips; do
            aws ec2 release-address --allocation-id "$eip" --region "$REGION" 2>/dev/null || true
        done

        # 3. VPC Endpoints
        print_info "  Deleting VPC Endpoints..."
        local endpoints=$(aws ec2 describe-vpc-endpoints --filters "Name=vpc-id,Values=$vpc_id" --region "$REGION" --query 'VpcEndpoints[*].VpcEndpointId' --output text)
        if [ -n "$endpoints" ]; then
            for endpoint in $endpoints; do
                aws ec2 delete-vpc-endpoints --vpc-endpoint-ids "$endpoint" --region "$REGION" 2>/dev/null || true
            done
            sleep 10
        fi

        # 4. Network Interfaces (retry)
        print_info "  Deleting Network Interfaces..."
        for i in {1..3}; do
            local enis=$(aws ec2 describe-network-interfaces --filters "Name=vpc-id,Values=$vpc_id" --region "$REGION" --query 'NetworkInterfaces[*].NetworkInterfaceId' --output text)
            [ -z "$enis" ] && break
            for eni in $enis; do
                aws ec2 delete-network-interface --network-interface-id "$eni" --region "$REGION" 2>/dev/null || true
            done
            sleep 5
        done

        # 5. Security Groups - revoke all rules first
        print_info "  Cleaning Security Groups..."
        local sgs=$(aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$vpc_id" --region "$REGION" --query 'SecurityGroups[?GroupName!=`default`].GroupId' --output text)

        # Revoke all rules
        for sg in $sgs; do
            aws ec2 describe-security-groups --group-ids "$sg" --region "$REGION" --query 'SecurityGroups[0].IpPermissions' --output json 2>/dev/null | \
                jq -c '.[]?' 2>/dev/null | while read rule; do
                    aws ec2 revoke-security-group-ingress --group-id "$sg" --ip-permissions "$rule" --region "$REGION" 2>/dev/null || true
                done

            aws ec2 describe-security-groups --group-ids "$sg" --region "$REGION" --query 'SecurityGroups[0].IpPermissionsEgress' --output json 2>/dev/null | \
                jq -c '.[]?' 2>/dev/null | while read rule; do
                    aws ec2 revoke-security-group-egress --group-id "$sg" --ip-permissions "$rule" --region "$REGION" 2>/dev/null || true
                done
        done

        # Delete security groups
        for sg in $sgs; do
            retry aws ec2 delete-security-group --group-id "$sg" --region "$REGION" 2>/dev/null
        done

        # 6. Route Table Associations (AGGRESSIVE)
        print_info "  Deleting Route Table associations..."
        local rts=$(aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$vpc_id" --region "$REGION" --query 'RouteTables[?Associations[0].Main==`false`].RouteTableId' --output text)

        for rt in $rts; do
            # Get all associations for this route table
            local assocs=$(aws ec2 describe-route-tables --route-table-ids "$rt" --region "$REGION" --query 'RouteTables[0].Associations[*].RouteTableAssociationId' --output text 2>/dev/null)

            for assoc in $assocs; do
                print_info "    Disassociating: $assoc"
                aws ec2 disassociate-route-table --association-id "$assoc" --region "$REGION" 2>/dev/null || true
            done

            # Delete the route table
            retry aws ec2 delete-route-table --route-table-id "$rt" --region "$REGION" 2>/dev/null
        done

        # 7. Internet Gateways
        print_info "  Deleting Internet Gateways..."
        local igws=$(aws ec2 describe-internet-gateways --filters "Name=attachment.vpc-id,Values=$vpc_id" --region "$REGION" --query 'InternetGateways[*].InternetGatewayId' --output text)
        for igw in $igws; do
            aws ec2 detach-internet-gateway --internet-gateway-id "$igw" --vpc-id "$vpc_id" --region "$REGION" 2>/dev/null || true
            aws ec2 delete-internet-gateway --internet-gateway-id "$igw" --region "$REGION" 2>/dev/null || true
        done

        # 8. Subnets
        print_info "  Deleting Subnets..."
        local subnets=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$vpc_id" --region "$REGION" --query 'Subnets[*].SubnetId' --output text)
        for subnet in $subnets; do
            retry aws ec2 delete-subnet --subnet-id "$subnet" --region "$REGION" 2>/dev/null
        done

        # 9. VPC itself
        print_info "  Deleting VPC..."
        retry aws ec2 delete-vpc --vpc-id "$vpc_id" --region "$REGION" 2>/dev/null

        print_success "VPC $vpc_id deleted"
    done
}

cleanup_secrets() {
    print_step "Cleaning up Secrets..."

    local secrets=$(aws secretsmanager list-secrets --region "$REGION" --query "SecretList[?starts_with(Name, '${PROJECT_NAME}/${ENVIRONMENT}')].Name" --output text)

    if [ -n "$secrets" ]; then
        for secret in $secrets; do
            print_info "Deleting: $secret"
            aws secretsmanager delete-secret --secret-id "$secret" --force-delete-without-recovery --region "$REGION" 2>/dev/null || true
        done
        print_success "Secrets deleted"
    else
        print_info "No secrets found"
    fi
}

cleanup_kms_aliases() {
    print_step "Cleaning up KMS Aliases..."

    # Delete KMS alias for EKS
    local alias_name="alias/${PROJECT_NAME}-eks-${ENVIRONMENT}"

    if aws kms describe-alias --alias-name "$alias_name" --region "$REGION" 2>/dev/null; then
        print_info "Deleting KMS alias: $alias_name"
        aws kms delete-alias --alias-name "$alias_name" --region "$REGION" 2>/dev/null || true
        print_success "KMS alias deleted"
    else
        print_info "No KMS alias found"
    fi
}

cleanup_cloudwatch_logs() {
    print_step "Cleaning up CloudWatch Log Groups..."

    # List all log groups for the project
    local log_groups=$(aws logs describe-log-groups --region "$REGION" --query "logGroups[?contains(logGroupName, '${PROJECT_NAME}')].logGroupName" --output text)

    if [ -n "$log_groups" ]; then
        for log_group in $log_groups; do
            print_info "Deleting log group: $log_group"
            aws logs delete-log-group --log-group-name "$log_group" --region "$REGION" 2>/dev/null || true
        done
        print_success "CloudWatch log groups deleted"
    else
        print_info "No log groups found"
    fi
}

# =============================================================================
# Main
# =============================================================================

print_header
confirm_deletion

echo -e "\n${YELLOW}Starting AGGRESSIVE cleanup for: ${ENVIRONMENT}${NC}\n"

cleanup_cloudwatch_logs
cleanup_kms_aliases
cleanup_lambda
cleanup_rds
cleanup_eks_cluster
cleanup_vpc_aggressive
cleanup_secrets

echo -e "\n${GREEN}═══════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  Cleanup completed!${NC}"
echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}\n"
