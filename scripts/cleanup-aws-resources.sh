#!/bin/bash
# =============================================================================
# AWS Resource Cleanup Script - AGGRESSIVE MODE
# =============================================================================
# Forcefully deletes ALL AWS resources for FIAP Tech Challenge
# Covers: EKS, RDS, Lambda, API Gateway, VPC, ECR, IAM, KMS, S3, DynamoDB,
#         SQS, DocumentDB, EventBridge, Load Balancers, OIDC, CloudWatch
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
ENVIRONMENT="${1:-development}"
ACCOUNT_ID=""

# =============================================================================
# Functions
# =============================================================================

print_header() {
    echo -e "\n${BLUE}=================================================================${NC}"
    echo -e "${BLUE}  AWS Resource Cleanup (AGGRESSIVE) - ${ENVIRONMENT}${NC}"
    echo -e "${BLUE}=================================================================${NC}\n"
}

print_step() {
    echo -e "\n${YELLOW}>>> $1${NC}"
}

print_success() {
    echo -e "${GREEN}  OK: $1${NC}"
}

print_info() {
    echo -e "${BLUE}  $1${NC}"
}

print_error() {
    echo -e "${RED}  ERR: $1${NC}"
}

confirm_deletion() {
    if [ "$2" = "--force" ] || [ "$FORCE" = "true" ]; then
        return 0
    fi

    echo -e "${RED}WARNING: This will FORCEFULLY DELETE all resources for: ${ENVIRONMENT}${NC}"
    echo -e "${RED}This action CANNOT be undone!${NC}\n"
    read -p "Type 'DELETE' to confirm: " confirmation

    if [ "$confirmation" != "DELETE" ]; then
        echo -e "${YELLOW}Aborted.${NC}"
        exit 0
    fi
}

get_account_id() {
    ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null)
    if [ -z "$ACCOUNT_ID" ]; then
        print_error "Failed to get AWS account ID. Are AWS credentials configured?"
        exit 1
    fi
    print_info "AWS Account: $ACCOUNT_ID"
}

# Retry function
retry() {
    local max_attempts=3
    local attempt=1
    local cmd="$@"

    while [ $attempt -le $max_attempts ]; do
        if eval "$cmd" 2>/dev/null; then
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

cleanup_load_balancers() {
    print_step "Cleaning up Load Balancers and Target Groups..."

    # Delete all load balancers (ELBv2: ALB + NLB)
    local lbs=$(aws elbv2 describe-load-balancers --region "$REGION" \
        --query 'LoadBalancers[*].LoadBalancerArn' --output text 2>/dev/null)

    if [ -n "$lbs" ]; then
        for lb_arn in $lbs; do
            local lb_name=$(aws elbv2 describe-load-balancers --load-balancer-arns "$lb_arn" \
                --region "$REGION" --query 'LoadBalancers[0].LoadBalancerName' --output text 2>/dev/null)
            print_info "Deleting LB: $lb_name ($lb_arn)"

            # Delete listeners first
            local listeners=$(aws elbv2 describe-listeners --load-balancer-arn "$lb_arn" \
                --region "$REGION" --query 'Listeners[*].ListenerArn' --output text 2>/dev/null)
            for listener in $listeners; do
                aws elbv2 delete-listener --listener-arn "$listener" --region "$REGION" 2>/dev/null || true
            done

            aws elbv2 delete-load-balancer --load-balancer-arn "$lb_arn" --region "$REGION" 2>/dev/null || true
        done
        print_info "Waiting 15s for LB deletion..."
        sleep 15
        print_success "Load Balancers deleted"
    else
        print_info "No Load Balancers found"
    fi

    # Delete target groups
    local tgs=$(aws elbv2 describe-target-groups --region "$REGION" \
        --query 'TargetGroups[*].TargetGroupArn' --output json 2>/dev/null)

    if [ "$tgs" != "[]" ] && [ -n "$tgs" ]; then
        echo "$tgs" | python3 -c "
import json, sys, subprocess
arns = json.load(sys.stdin)
for arn in arns:
    subprocess.run(['aws', 'elbv2', 'delete-target-group', '--target-group-arn', arn, '--region', '$REGION'], capture_output=True)
" 2>/dev/null
        print_success "Target Groups deleted"
    else
        print_info "No Target Groups found"
    fi

    # Delete Classic ELBs
    local classic_lbs=$(aws elb describe-load-balancers --region "$REGION" \
        --query 'LoadBalancerDescriptions[*].LoadBalancerName' --output text 2>/dev/null)
    if [ -n "$classic_lbs" ]; then
        for clb in $classic_lbs; do
            print_info "Deleting Classic LB: $clb"
            aws elb delete-load-balancer --load-balancer-name "$clb" --region "$REGION" 2>/dev/null || true
        done
        print_success "Classic Load Balancers deleted"
    fi
}

cleanup_api_gateway() {
    print_step "Cleaning up API Gateways..."

    # HTTP/WebSocket APIs (v2)
    local apis=$(aws apigatewayv2 get-apis --region "$REGION" \
        --query 'Items[*].[ApiId,Name]' --output text 2>/dev/null)

    if [ -n "$apis" ]; then
        while IFS=$'\t' read -r api_id api_name; do
            print_info "Deleting API: $api_name ($api_id)"
            aws apigatewayv2 delete-api --api-id "$api_id" --region "$REGION" 2>/dev/null || true
        done <<< "$apis"
        print_success "API Gateways (v2) deleted"
    else
        print_info "No API Gateways (v2) found"
    fi

    # REST APIs (v1)
    local rest_apis=$(aws apigateway get-rest-apis --region "$REGION" \
        --query "items[?contains(name, '${PROJECT_NAME}')].id" --output text 2>/dev/null)

    if [ -n "$rest_apis" ]; then
        for api_id in $rest_apis; do
            print_info "Deleting REST API: $api_id"
            aws apigateway delete-rest-api --rest-api-id "$api_id" --region "$REGION" 2>/dev/null || true
        done
        print_success "REST API Gateways deleted"
    fi
}

cleanup_lambda() {
    print_step "Cleaning up Lambda functions..."

    local functions=$(aws lambda list-functions --region "$REGION" \
        --query "Functions[?starts_with(FunctionName, '${PROJECT_NAME}')].FunctionName" --output text 2>/dev/null)

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

cleanup_rds() {
    print_step "Cleaning up RDS instances..."

    # Find all RDS instances with project prefix
    local instances=$(aws rds describe-db-instances --region "$REGION" \
        --query "DBInstances[?starts_with(DBInstanceIdentifier, '${PROJECT_NAME}')].[DBInstanceIdentifier,DBInstanceStatus]" --output text 2>/dev/null)

    if [ -n "$instances" ]; then
        while IFS=$'\t' read -r db_id db_status; do
            print_info "Deleting RDS: $db_id (status: $db_status)"
            aws rds delete-db-instance \
                --db-instance-identifier "$db_id" \
                --skip-final-snapshot \
                --delete-automated-backups \
                --region "$REGION" 2>/dev/null || true
        done <<< "$instances"

        print_info "Waiting for RDS deletion (can take several minutes)..."
        while IFS=$'\t' read -r db_id db_status; do
            aws rds wait db-instance-deleted --db-instance-identifier "$db_id" --region "$REGION" 2>/dev/null || true
        done <<< "$instances"

        print_success "RDS instances deleted"
    else
        print_info "No RDS instances found"
    fi

    # Delete DB subnet groups
    local subnet_groups=$(aws rds describe-db-subnet-groups --region "$REGION" \
        --query "DBSubnetGroups[?starts_with(DBSubnetGroupName, '${PROJECT_NAME}')].DBSubnetGroupName" --output text 2>/dev/null)

    for sg in $subnet_groups; do
        print_info "Deleting DB subnet group: $sg"
        aws rds delete-db-subnet-group --db-subnet-group-name "$sg" --region "$REGION" 2>/dev/null || true
    done
}

cleanup_documentdb() {
    print_step "Cleaning up DocumentDB..."

    local clusters=$(aws docdb describe-db-clusters --region "$REGION" \
        --query "DBClusters[?starts_with(DBClusterIdentifier, '${PROJECT_NAME}')].[DBClusterIdentifier,Status]" --output text 2>/dev/null)

    if [ -n "$clusters" ]; then
        while IFS=$'\t' read -r cluster_id status; do
            print_info "Found DocumentDB cluster: $cluster_id (status: $status)"

            # Delete instances first
            local instances=$(aws docdb describe-db-instances --region "$REGION" \
                --query "DBInstances[?DBClusterIdentifier=='${cluster_id}'].DBInstanceIdentifier" --output text 2>/dev/null)

            for inst in $instances; do
                print_info "  Deleting instance: $inst"
                aws docdb delete-db-instance --db-instance-identifier "$inst" --region "$REGION" 2>/dev/null || true
            done

            # Wait for instances to be deleted
            for inst in $instances; do
                aws docdb wait db-instance-deleted --db-instance-identifier "$inst" --region "$REGION" 2>/dev/null || true
            done

            # Delete cluster
            print_info "  Deleting cluster: $cluster_id"
            aws docdb delete-db-cluster --db-cluster-identifier "$cluster_id" \
                --skip-final-snapshot --region "$REGION" 2>/dev/null || true
        done

        print_success "DocumentDB cleaned"
    else
        print_info "No DocumentDB clusters found"
    fi
}

cleanup_dynamodb() {
    print_step "Cleaning up DynamoDB tables..."

    local tables=$(aws dynamodb list-tables --region "$REGION" --query 'TableNames' --output json 2>/dev/null)

    if [ "$tables" != "[]" ] && [ -n "$tables" ]; then
        echo "$tables" | python3 -c "
import json, sys, subprocess
tables = json.load(sys.stdin)
for table in tables:
    if 'fiap' in table.lower():
        print(f'  Deleting: {table}')
        subprocess.run(['aws', 'dynamodb', 'delete-table', '--table-name', table, '--region', '$REGION'], capture_output=True)
" 2>/dev/null
        print_success "DynamoDB tables deleted"
    else
        print_info "No DynamoDB tables found"
    fi
}

cleanup_sqs() {
    print_step "Cleaning up SQS queues..."

    local queues=$(aws sqs list-queues --region "$REGION" \
        --queue-name-prefix "$PROJECT_NAME" --query 'QueueUrls[*]' --output text 2>/dev/null)

    if [ -n "$queues" ]; then
        for queue_url in $queues; do
            print_info "Deleting: $queue_url"
            aws sqs delete-queue --queue-url "$queue_url" --region "$REGION" 2>/dev/null || true
        done
        print_success "SQS queues deleted"
    else
        print_info "No SQS queues found"
    fi
}

cleanup_eventbridge() {
    print_step "Cleaning up EventBridge..."

    local buses=$(aws events list-event-buses --region "$REGION" \
        --query "EventBuses[?starts_with(Name, '${PROJECT_NAME}')].Name" --output text 2>/dev/null)

    if [ -n "$buses" ]; then
        for bus in $buses; do
            # Delete rules first
            local rules=$(aws events list-rules --event-bus-name "$bus" --region "$REGION" \
                --query 'Rules[*].Name' --output text 2>/dev/null)

            for rule in $rules; do
                # Remove targets first
                local targets=$(aws events list-targets-by-rule --event-bus-name "$bus" --rule "$rule" \
                    --region "$REGION" --query 'Targets[*].Id' --output text 2>/dev/null)
                if [ -n "$targets" ]; then
                    aws events remove-targets --event-bus-name "$bus" --rule "$rule" \
                        --ids $targets --region "$REGION" 2>/dev/null || true
                fi

                print_info "  Deleting rule: $rule"
                aws events delete-rule --event-bus-name "$bus" --name "$rule" --region "$REGION" 2>/dev/null || true
            done

            print_info "Deleting event bus: $bus"
            aws events delete-event-bus --name "$bus" --region "$REGION" 2>/dev/null || true
        done
        print_success "EventBridge cleaned"
    else
        print_info "No EventBridge buses found"
    fi
}

cleanup_kubernetes_resources() {
    print_step "Cleaning up Kubernetes resources..."

    local cluster_name="${PROJECT_NAME}-eks-${ENVIRONMENT}"

    # Check if cluster exists
    if ! aws eks describe-cluster --name "$cluster_name" --region "$REGION" &>/dev/null; then
        print_info "No EKS cluster found - skipping Kubernetes cleanup"
        return 0
    fi

    # Configure kubectl
    print_info "Configuring kubectl for cluster: $cluster_name"
    if ! aws eks update-kubeconfig --region "$REGION" --name "$cluster_name" > /dev/null 2>&1; then
        print_info "Failed to configure kubectl"
        return 0
    fi

    # Delete all non-system namespaces
    print_info "Deleting application namespaces..."
    for ns in "ftc-app-${ENVIRONMENT}" "ftc-app-development" "ftc-app-production" signoz; do
        kubectl delete namespace "$ns" --ignore-not-found=true --timeout=60s 2>/dev/null || true
    done

    # Delete remaining resources
    print_info "Deleting remaining Kubernetes resources..."
    kubectl delete deployment,service,ingress,hpa,pdb --all --all-namespaces --ignore-not-found=true --timeout=60s 2>/dev/null || true

    print_info "Waiting 30s for finalizers..."
    sleep 30

    print_success "Kubernetes resources cleaned"
}

cleanup_eks_cluster() {
    print_step "Cleaning up EKS clusters..."

    # Delete ALL clusters, not just the current environment
    local clusters=$(aws eks list-clusters --region "$REGION" --query 'clusters[*]' --output text 2>/dev/null)

    if [ -n "$clusters" ]; then
        for cluster_name in $clusters; do
            print_info "Found EKS cluster: $cluster_name"

            # Delete Fargate profiles
            local fargate_profiles=$(aws eks list-fargate-profiles --cluster-name "$cluster_name" \
                --region "$REGION" --query 'fargateProfileNames[*]' --output text 2>/dev/null)
            for fp in $fargate_profiles; do
                print_info "  Deleting Fargate profile: $fp"
                aws eks delete-fargate-profile --cluster-name "$cluster_name" \
                    --fargate-profile-name "$fp" --region "$REGION" 2>/dev/null || true
            done

            # Delete node groups
            local nodegroups=$(aws eks list-nodegroups --cluster-name "$cluster_name" \
                --region "$REGION" --query 'nodegroups[*]' --output text 2>/dev/null)
            for ng in $nodegroups; do
                print_info "  Deleting node group: $ng"
                aws eks delete-nodegroup --cluster-name "$cluster_name" \
                    --nodegroup-name "$ng" --region "$REGION" 2>/dev/null || true
            done

            if [ -n "$nodegroups" ]; then
                print_info "  Waiting for node groups to delete..."
                for ng in $nodegroups; do
                    aws eks wait nodegroup-deleted --cluster-name "$cluster_name" \
                        --nodegroup-name "$ng" --region "$REGION" 2>/dev/null || true
                done
            fi

            # Delete cluster
            print_info "  Deleting EKS cluster: $cluster_name"
            aws eks delete-cluster --name "$cluster_name" --region "$REGION" 2>/dev/null || true

            print_info "  Waiting for cluster deletion..."
            aws eks wait cluster-deleted --name "$cluster_name" --region "$REGION" 2>/dev/null || true

            print_success "EKS cluster $cluster_name deleted"
        done
    else
        print_info "No EKS clusters found"
    fi
}

cleanup_ecr() {
    print_step "Cleaning up ECR repositories..."

    # Get ALL ECR repositories (not just project-prefixed ones)
    local repos=$(aws ecr describe-repositories --region "$REGION" \
        --query 'repositories[*].repositoryName' --output text 2>/dev/null)

    if [ -n "$repos" ]; then
        for repo in $repos; do
            print_info "Deleting ECR repository: $repo"
            aws ecr delete-repository --repository-name "$repo" --region "$REGION" --force 2>/dev/null || true
        done
        print_success "ECR repositories deleted"
    else
        print_info "No ECR repositories found"
    fi
}

cleanup_secrets() {
    print_step "Cleaning up Secrets Manager..."

    # Find ALL secrets with project prefix (any environment)
    local secrets=$(aws secretsmanager list-secrets --region "$REGION" \
        --query "SecretList[?starts_with(Name, '${PROJECT_NAME}')].Name" --output text 2>/dev/null)

    if [ -n "$secrets" ]; then
        for secret in $secrets; do
            print_info "Deleting: $secret"
            aws secretsmanager delete-secret --secret-id "$secret" \
                --force-delete-without-recovery --region "$REGION" 2>/dev/null || true
        done
        print_success "Secrets deleted"
    else
        print_info "No secrets found"
    fi
}

cleanup_kms() {
    print_step "Cleaning up KMS keys and aliases..."

    # Delete KMS aliases
    local aliases=$(aws kms list-aliases --region "$REGION" \
        --query "Aliases[?starts_with(AliasName, 'alias/${PROJECT_NAME}')].AliasName" --output text 2>/dev/null)

    for alias in $aliases; do
        print_info "Deleting KMS alias: $alias"
        aws kms delete-alias --alias-name "$alias" --region "$REGION" 2>/dev/null || true
    done

    # Schedule KMS keys for deletion
    local keys=$(aws kms list-keys --region "$REGION" --query 'Keys[*].KeyId' --output text 2>/dev/null)
    for key in $keys; do
        local desc=$(aws kms describe-key --key-id "$key" --region "$REGION" \
            --query 'KeyMetadata.[Description,KeyState]' --output text 2>/dev/null)
        if echo "$desc" | grep -qi "$PROJECT_NAME"; then
            local state=$(echo "$desc" | awk '{print $NF}')
            if [ "$state" = "Enabled" ]; then
                print_info "Scheduling KMS key deletion: $key"
                aws kms schedule-key-deletion --key-id "$key" --pending-window-in-days 7 \
                    --region "$REGION" 2>/dev/null || true
            fi
        fi
    done

    print_success "KMS cleanup done"
}

cleanup_oidc_providers() {
    print_step "Cleaning up OIDC providers..."

    local providers=$(aws iam list-open-id-connect-providers \
        --query 'OpenIDConnectProviderList[*].Arn' --output text 2>/dev/null)

    if [ -n "$providers" ]; then
        for provider_arn in $providers; do
            if echo "$provider_arn" | grep -q "eks"; then
                print_info "Deleting OIDC provider: $provider_arn"
                aws iam delete-open-id-connect-provider \
                    --open-id-connect-provider-arn "$provider_arn" 2>/dev/null || true
            fi
        done
        print_success "OIDC providers cleaned"
    else
        print_info "No OIDC providers found"
    fi
}

cleanup_cloudwatch_logs() {
    print_step "Cleaning up CloudWatch Log Groups..."

    local log_groups=$(aws logs describe-log-groups --region "$REGION" \
        --query 'logGroups[*].logGroupName' --output json 2>/dev/null)

    if [ "$log_groups" != "[]" ] && [ -n "$log_groups" ]; then
        echo "$log_groups" | python3 -c "
import json, sys, subprocess
groups = json.load(sys.stdin)
keywords = ['fiap', 'eks', 'containerinsights', 'ftc']
for g in groups:
    if any(kw in g.lower() for kw in keywords):
        print(f'  Deleting: {g}')
        subprocess.run(['aws', 'logs', 'delete-log-group', '--log-group-name', g, '--region', '$REGION'], capture_output=True)
" 2>/dev/null
        print_success "CloudWatch log groups deleted"
    else
        print_info "No matching log groups found"
    fi
}

cleanup_iam_roles_and_policies() {
    print_step "Cleaning up IAM Roles and Policies..."

    local roles=$(aws iam list-roles \
        --query "Roles[?contains(RoleName, '${PROJECT_NAME}')].RoleName" --output text 2>/dev/null)

    if [ -n "$roles" ]; then
        for role in $roles; do
            print_info "Processing role: $role"

            # Detach managed policies
            local attached_policies=$(aws iam list-attached-role-policies --role-name "$role" \
                --query 'AttachedPolicies[*].PolicyArn' --output text 2>/dev/null)
            for policy_arn in $attached_policies; do
                aws iam detach-role-policy --role-name "$role" --policy-arn "$policy_arn" 2>/dev/null || true
            done

            # Delete inline policies
            local inline_policies=$(aws iam list-role-policies --role-name "$role" \
                --query 'PolicyNames[*]' --output text 2>/dev/null)
            for policy_name in $inline_policies; do
                aws iam delete-role-policy --role-name "$role" --policy-name "$policy_name" 2>/dev/null || true
            done

            # Remove from instance profiles
            local instance_profiles=$(aws iam list-instance-profiles-for-role --role-name "$role" \
                --query 'InstanceProfiles[*].InstanceProfileName' --output text 2>/dev/null)
            for profile in $instance_profiles; do
                aws iam remove-role-from-instance-profile \
                    --instance-profile-name "$profile" --role-name "$role" 2>/dev/null || true
                aws iam delete-instance-profile --instance-profile-name "$profile" 2>/dev/null || true
            done

            # Delete the role
            retry aws iam delete-role --role-name "$role"
            print_info "  Deleted: $role"
        done
        print_success "IAM roles cleaned"
    else
        print_info "No IAM roles found"
    fi

    # Delete custom policies
    local policies=$(aws iam list-policies --scope Local \
        --query "Policies[?contains(PolicyName, '${PROJECT_NAME}')].Arn" --output text 2>/dev/null)

    if [ -n "$policies" ]; then
        for policy_arn in $policies; do
            print_info "Deleting policy: $policy_arn"

            # Detach from all entities
            for entity_type in Role User Group; do
                local filter=$(echo "$entity_type" | tr '[:upper:]' '[:lower:]')
                local entities=$(aws iam list-entities-for-policy --policy-arn "$policy_arn" \
                    --entity-filter "$entity_type" --query "Policy${entity_type}s[*].${entity_type}Name" --output text 2>/dev/null)
                for entity in $entities; do
                    aws iam "detach-${filter}-policy" --"${filter}-name" "$entity" --policy-arn "$policy_arn" 2>/dev/null || true
                done
            done

            # Delete non-default versions
            local versions=$(aws iam list-policy-versions --policy-arn "$policy_arn" \
                --query 'Versions[?!IsDefaultVersion].VersionId' --output text 2>/dev/null)
            for version in $versions; do
                aws iam delete-policy-version --policy-arn "$policy_arn" --version-id "$version" 2>/dev/null || true
            done

            retry aws iam delete-policy --policy-arn "$policy_arn"
        done
        print_success "IAM policies deleted"
    fi
}

cleanup_vpc_aggressive() {
    print_step "AGGRESSIVE VPC cleanup..."

    # Find ALL non-default VPCs (not just tagged ones - catches orphaned VPCs)
    local vpc_ids=$(aws ec2 describe-vpcs \
        --filters "Name=is-default,Values=false" \
        --region "$REGION" \
        --query 'Vpcs[*].VpcId' \
        --output text 2>/dev/null)

    if [ -z "$vpc_ids" ]; then
        print_info "No non-default VPCs found"
        return
    fi

    for vpc_id in $vpc_ids; do
        local vpc_name=$(aws ec2 describe-vpcs --vpc-ids "$vpc_id" --region "$REGION" \
            --query 'Vpcs[0].Tags[?Key==`Name`].Value | [0]' --output text 2>/dev/null)
        print_info "Processing VPC: $vpc_id ($vpc_name)"

        # 1. NAT Gateways
        print_info "  Deleting NAT Gateways..."
        local nats=$(aws ec2 describe-nat-gateways \
            --filter "Name=vpc-id,Values=$vpc_id" "Name=state,Values=available,pending" \
            --region "$REGION" --query 'NatGateways[*].NatGatewayId' --output text 2>/dev/null)
        for nat in $nats; do
            aws ec2 delete-nat-gateway --nat-gateway-id "$nat" --region "$REGION" 2>/dev/null || true
        done
        [ -n "$nats" ] && { print_info "  Waiting 60s for NAT Gateway deletion..."; sleep 60; }

        # 2. Elastic IPs (all in account, not just VPC-specific)
        print_info "  Releasing Elastic IPs..."
        local eips=$(aws ec2 describe-addresses --region "$REGION" \
            --query 'Addresses[?AssociationId==null].AllocationId' --output text 2>/dev/null)
        for eip in $eips; do
            aws ec2 release-address --allocation-id "$eip" --region "$REGION" 2>/dev/null || true
        done

        # 3. VPC Endpoints
        print_info "  Deleting VPC Endpoints..."
        local endpoints=$(aws ec2 describe-vpc-endpoints \
            --filters "Name=vpc-id,Values=$vpc_id" \
            --region "$REGION" --query 'VpcEndpoints[*].VpcEndpointId' --output text 2>/dev/null)
        if [ -n "$endpoints" ]; then
            aws ec2 delete-vpc-endpoints --vpc-endpoint-ids $endpoints --region "$REGION" 2>/dev/null || true
            sleep 10
        fi

        # 4. Network Interfaces (retry)
        print_info "  Deleting Network Interfaces..."
        for i in {1..3}; do
            local enis=$(aws ec2 describe-network-interfaces \
                --filters "Name=vpc-id,Values=$vpc_id" \
                --region "$REGION" --query 'NetworkInterfaces[*].[NetworkInterfaceId,Attachment.AttachmentId]' --output text 2>/dev/null)
            [ -z "$enis" ] && break
            while IFS=$'\t' read -r eni_id attachment_id; do
                if [ -n "$attachment_id" ] && [ "$attachment_id" != "None" ]; then
                    aws ec2 detach-network-interface --attachment-id "$attachment_id" --force \
                        --region "$REGION" 2>/dev/null || true
                fi
                sleep 2
                aws ec2 delete-network-interface --network-interface-id "$eni_id" \
                    --region "$REGION" 2>/dev/null || true
            done <<< "$enis"
            sleep 5
        done

        # 5. Security Groups - revoke all rules first to break circular refs
        print_info "  Cleaning Security Groups..."
        local sgs=$(aws ec2 describe-security-groups \
            --filters "Name=vpc-id,Values=$vpc_id" \
            --region "$REGION" --query 'SecurityGroups[?GroupName!=`default`].GroupId' --output text 2>/dev/null)

        # Phase 1: Revoke all rules
        for sg in $sgs; do
            local ingress=$(aws ec2 describe-security-groups --group-ids "$sg" --region "$REGION" \
                --query 'SecurityGroups[0].IpPermissions' --output json 2>/dev/null)
            local egress=$(aws ec2 describe-security-groups --group-ids "$sg" --region "$REGION" \
                --query 'SecurityGroups[0].IpPermissionsEgress' --output json 2>/dev/null)

            if [ "$ingress" != "[]" ] && [ -n "$ingress" ]; then
                aws ec2 revoke-security-group-ingress --group-id "$sg" --ip-permissions "$ingress" \
                    --region "$REGION" 2>/dev/null || true
            fi
            if [ "$egress" != "[]" ] && [ -n "$egress" ]; then
                aws ec2 revoke-security-group-egress --group-id "$sg" --ip-permissions "$egress" \
                    --region "$REGION" 2>/dev/null || true
            fi
        done

        # Phase 2: Delete security groups
        for sg in $sgs; do
            retry aws ec2 delete-security-group --group-id "$sg" --region "$REGION"
        done

        # 6. Route Table Associations
        print_info "  Deleting Route Tables..."
        local rts=$(aws ec2 describe-route-tables \
            --filters "Name=vpc-id,Values=$vpc_id" \
            --region "$REGION" --query 'RouteTables[?Associations[0].Main!=`true`].RouteTableId' --output text 2>/dev/null)

        for rt in $rts; do
            local assocs=$(aws ec2 describe-route-tables --route-table-ids "$rt" --region "$REGION" \
                --query 'RouteTables[0].Associations[?!Main].RouteTableAssociationId' --output text 2>/dev/null)
            for assoc in $assocs; do
                aws ec2 disassociate-route-table --association-id "$assoc" --region "$REGION" 2>/dev/null || true
            done
            retry aws ec2 delete-route-table --route-table-id "$rt" --region "$REGION"
        done

        # 7. Internet Gateways
        print_info "  Deleting Internet Gateways..."
        local igws=$(aws ec2 describe-internet-gateways \
            --filters "Name=attachment.vpc-id,Values=$vpc_id" \
            --region "$REGION" --query 'InternetGateways[*].InternetGatewayId' --output text 2>/dev/null)
        for igw in $igws; do
            aws ec2 detach-internet-gateway --internet-gateway-id "$igw" --vpc-id "$vpc_id" \
                --region "$REGION" 2>/dev/null || true
            aws ec2 delete-internet-gateway --internet-gateway-id "$igw" --region "$REGION" 2>/dev/null || true
        done

        # 8. Subnets
        print_info "  Deleting Subnets..."
        local subnets=$(aws ec2 describe-subnets \
            --filters "Name=vpc-id,Values=$vpc_id" \
            --region "$REGION" --query 'Subnets[*].SubnetId' --output text 2>/dev/null)
        for subnet in $subnets; do
            retry aws ec2 delete-subnet --subnet-id "$subnet" --region "$REGION"
        done

        # 9. VPC itself
        print_info "  Deleting VPC..."
        retry aws ec2 delete-vpc --vpc-id "$vpc_id" --region "$REGION"

        print_success "VPC $vpc_id ($vpc_name) deleted"
    done
}

cleanup_s3_state_bucket() {
    print_step "Cleaning up S3 Terraform state bucket..."

    local bucket_name="${PROJECT_NAME}-tf-state-${ACCOUNT_ID}"

    if aws s3api head-bucket --bucket "$bucket_name" --region "$REGION" 2>/dev/null; then
        print_info "Found bucket: $bucket_name"

        # Delete all object versions (handles versioned buckets)
        print_info "Deleting all objects and versions..."
        python3 -c "
import json, subprocess, sys

bucket = '$bucket_name'
region = '$REGION'

# List all versions
result = subprocess.run(
    ['aws', 's3api', 'list-object-versions', '--bucket', bucket, '--region', region, '--output', 'json'],
    capture_output=True, text=True
)

if result.returncode != 0:
    print('  No versions found or error')
    sys.exit(0)

data = json.loads(result.stdout)
objects = []

for v in data.get('Versions', []):
    objects.append({'Key': v['Key'], 'VersionId': v['VersionId']})
for dm in data.get('DeleteMarkers', []):
    objects.append({'Key': dm['Key'], 'VersionId': dm['VersionId']})

if not objects:
    print('  Bucket is empty')
    sys.exit(0)

# Delete in batches
for i in range(0, len(objects), 1000):
    batch = objects[i:i+1000]
    payload = json.dumps({'Objects': batch, 'Quiet': True})
    subprocess.run(
        ['aws', 's3api', 'delete-objects', '--bucket', bucket, '--delete', payload, '--region', region],
        capture_output=True
    )
    print(f'  Deleted {len(batch)} objects/versions')
" 2>/dev/null

        # Delete the bucket
        print_info "Deleting bucket..."
        aws s3 rb "s3://$bucket_name" --region "$REGION" 2>/dev/null || true

        print_success "S3 state bucket deleted"
    else
        print_info "No S3 state bucket found"
    fi
}

# =============================================================================
# Validation
# =============================================================================

validate_cleanup() {
    print_step "Validating cleanup..."

    local issues=0

    check_resource() {
        local name="$1"
        local result="$2"
        if [ -n "$result" ] && [ "$result" != "[]" ] && [ "$result" != "None" ]; then
            print_error "$name still exists: $result"
            issues=$((issues + 1))
        else
            print_info "$name: clean"
        fi
    }

    check_resource "EKS Clusters" "$(aws eks list-clusters --region "$REGION" --query 'clusters[*]' --output text 2>/dev/null)"
    check_resource "RDS" "$(aws rds describe-db-instances --region "$REGION" --query 'DBInstances[*].DBInstanceIdentifier' --output text 2>/dev/null)"
    check_resource "EC2 Instances" "$(aws ec2 describe-instances --region "$REGION" --filters 'Name=instance-state-name,Values=running,pending' --query 'Reservations[*].Instances[*].InstanceId' --output text 2>/dev/null)"
    check_resource "Non-default VPCs" "$(aws ec2 describe-vpcs --region "$REGION" --filters 'Name=is-default,Values=false' --query 'Vpcs[*].VpcId' --output text 2>/dev/null)"
    check_resource "Load Balancers" "$(aws elbv2 describe-load-balancers --region "$REGION" --query 'LoadBalancers[*].LoadBalancerName' --output text 2>/dev/null)"
    check_resource "NAT Gateways" "$(aws ec2 describe-nat-gateways --region "$REGION" --filter 'Name=state,Values=available,pending' --query 'NatGateways[*].NatGatewayId' --output text 2>/dev/null)"
    check_resource "Elastic IPs" "$(aws ec2 describe-addresses --region "$REGION" --query 'Addresses[*].AllocationId' --output text 2>/dev/null)"
    check_resource "Lambda" "$(aws lambda list-functions --region "$REGION" --query 'Functions[*].FunctionName' --output text 2>/dev/null)"
    check_resource "API Gateway" "$(aws apigatewayv2 get-apis --region "$REGION" --query 'Items[*].Name' --output text 2>/dev/null)"
    check_resource "ECR" "$(aws ecr describe-repositories --region "$REGION" --query 'repositories[*].repositoryName' --output text 2>/dev/null)"
    check_resource "IAM Roles" "$(aws iam list-roles --query "Roles[?contains(RoleName, '${PROJECT_NAME}')].RoleName" --output text 2>/dev/null)"
    check_resource "S3 (fiap)" "$(aws s3 ls 2>&1 | grep -i fiap || true)"

    if [ $issues -eq 0 ]; then
        print_success "All resources cleaned up!"
    else
        print_error "$issues resource type(s) still have remaining items"
    fi
}

# =============================================================================
# Main
# =============================================================================

# Parse --force flag from any position
for arg in "$@"; do
    if [ "$arg" = "--force" ]; then
        FORCE="true"
    fi
done

print_header
get_account_id
confirm_deletion

echo -e "\n${YELLOW}Starting AGGRESSIVE cleanup...${NC}\n"

# Phase 1: Application layer
cleanup_load_balancers
cleanup_api_gateway
cleanup_lambda

# Phase 2: Data layer
cleanup_rds
cleanup_documentdb
cleanup_dynamodb
cleanup_sqs
cleanup_eventbridge

# Phase 3: Kubernetes
cleanup_kubernetes_resources
cleanup_eks_cluster

# Phase 4: Infrastructure
cleanup_kms
cleanup_cloudwatch_logs
cleanup_vpc_aggressive
cleanup_secrets
cleanup_ecr

# Phase 5: IAM & State
cleanup_iam_roles_and_policies
cleanup_oidc_providers
cleanup_s3_state_bucket

# Phase 6: Validation
validate_cleanup

# Cleanup local kubectl config
print_step "Cleaning local kubectl config..."
kubectl config unset current-context 2>/dev/null || true
for ctx in $(kubectl config get-contexts -o name 2>/dev/null | grep -iE "fiap|eks" || true); do
    kubectl config delete-context "$ctx" 2>/dev/null || true
done
for cluster in $(kubectl config get-clusters 2>/dev/null | grep -iE "fiap|eks" || true); do
    kubectl config delete-cluster "$cluster" 2>/dev/null || true
done

echo -e "\n${GREEN}=================================================================${NC}"
echo -e "${GREEN}  Cleanup completed!${NC}"
echo -e "${GREEN}=================================================================${NC}\n"
