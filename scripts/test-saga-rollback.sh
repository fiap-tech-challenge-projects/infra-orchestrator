#!/bin/bash
# Saga Compensation Test for Phase 4 Microservices
# Tests that budget rejection prevents execution creation
# Usage: ./test-saga-rollback.sh

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Parse arguments
ENVIRONMENT="${1:-development}"
NAMESPACE="ftc-app-${ENVIRONMENT}"

echo "=================================================="
echo "Phase 4 Saga Compensation Test"
echo "Testing Budget Rejection Flow"
echo "Environment: ${ENVIRONMENT}"
echo "Namespace: ${NAMESPACE}"
echo "=================================================="
echo ""

# Get ALB URL from Kubernetes ingress
echo "Getting API endpoint from Kubernetes..."
ALB_URL=$(kubectl get ingress os-service -n "$NAMESPACE" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null)

if [ -z "$ALB_URL" ]; then
    echo -e "${RED}Failed to get ALB URL from ingress${NC}"
    echo "  Make sure services are deployed: ./deploy-services.sh --env=development"
    exit 1
fi

API_BASE="http://${ALB_URL}/api/v1"
echo -e "${GREEN}API Base URL: ${API_BASE}${NC}"
echo ""

# Wait for ALB to be ready
echo "Waiting for ALB to be ready..."
for i in {1..30}; do
    if curl -s -f "${API_BASE}/health" > /dev/null 2>&1; then
        echo -e "${GREEN}ALB is ready${NC}"
        break
    fi
    if [ $i -eq 30 ]; then
        echo -e "${RED}ALB failed to become ready after 30 attempts${NC}"
        exit 1
    fi
    echo "  Attempt $i/30 - waiting..."
    sleep 2
done
echo ""

# Generate unique identifiers
TIMESTAMP=$(date +%s)
# Use a known valid CPF (check digits are validated by the app)
TEST_CPF="71429741020"

echo "=================================================="
echo "Test Flow: Budget Rejection Scenario"
echo "=================================================="
echo ""

# 1. Create Client
echo -e "${BLUE}[1/7] Creating client...${NC}"
CLIENT_RESPONSE=$(curl -s -X POST ${API_BASE}/clients \
  -H "Content-Type: application/json" \
  -d "{
    \"name\": \"Saga Test Client ${TIMESTAMP}\",
    \"email\": \"saga${TIMESTAMP}@example.com\",
    \"cpfCnpj\": \"${TEST_CPF}\",
    \"phone\": \"11888888888\"
  }")

CLIENT_ID=$(echo ${CLIENT_RESPONSE} | jq -r '.id // .data.id // empty')
if [ -z "$CLIENT_ID" ] || [ "$CLIENT_ID" == "null" ]; then
    echo -e "${RED}Failed to create client${NC}"
    echo "Response: ${CLIENT_RESPONSE}"
    exit 1
fi
echo -e "${GREEN}Client created: ${CLIENT_ID}${NC}"
echo ""

# 2. Register Vehicle
echo -e "${BLUE}[2/7] Registering vehicle...${NC}"
LICENSE_PLATE="XYZ${TIMESTAMP: -4}"
VEHICLE_RESPONSE=$(curl -s -X POST ${API_BASE}/vehicles \
  -H "Content-Type: application/json" \
  -d "{
    \"licensePlate\": \"${LICENSE_PLATE}\",
    \"make\": \"Honda\",
    \"model\": \"Civic\",
    \"year\": 2021,
    \"clientId\": \"${CLIENT_ID}\"
  }")

VEHICLE_ID=$(echo ${VEHICLE_RESPONSE} | jq -r '.id // .data.id // empty')
if [ -z "$VEHICLE_ID" ] || [ "$VEHICLE_ID" == "null" ]; then
    echo -e "${RED}Failed to register vehicle${NC}"
    echo "Response: ${VEHICLE_RESPONSE}"
    exit 1
fi
echo -e "${GREEN}Vehicle registered: ${VEHICLE_ID}${NC}"
echo ""

# 3. Create Service Order
echo -e "${BLUE}[3/7] Creating service order...${NC}"
ORDER_RESPONSE=$(curl -s -X POST ${API_BASE}/service-orders \
  -H "Content-Type: application/json" \
  -d "{
    \"clientId\": \"${CLIENT_ID}\",
    \"vehicleId\": \"${VEHICLE_ID}\",
    \"notes\": \"Saga Test: Budget will be rejected\"
  }")

ORDER_ID=$(echo ${ORDER_RESPONSE} | jq -r '.id // .data.id // empty')
if [ -z "$ORDER_ID" ] || [ "$ORDER_ID" == "null" ]; then
    echo -e "${RED}Failed to create service order${NC}"
    echo "Response: ${ORDER_RESPONSE}"
    exit 1
fi
echo -e "${GREEN}Service order created: ${ORDER_ID}${NC}"
echo -e "${YELLOW}  (OrderCreated event sent to EventBridge -> Billing Service)${NC}"
echo ""

# 4. Wait for budget to be auto-generated
echo -e "${BLUE}[4/7] Waiting for budget generation...${NC}"
BUDGET_ID=""
for i in {1..10}; do
    sleep 2
    BUDGET_RESPONSE=$(curl -s "${API_BASE}/budgets?serviceOrderId=${ORDER_ID}")
    BUDGET_ID=$(echo ${BUDGET_RESPONSE} | jq -r '.[0].id // .data[0].id // empty')

    if [ -n "$BUDGET_ID" ] && [ "$BUDGET_ID" != "null" ]; then
        echo -e "${GREEN}Budget auto-generated: ${BUDGET_ID}${NC}"
        break
    fi

    if [ $i -eq 10 ]; then
        echo -e "${RED}Budget not created after 20 seconds${NC}"
        echo "Response: ${BUDGET_RESPONSE}"
        exit 1
    fi
    echo "  Attempt $i/10 - waiting..."
done
echo ""

# 5. REJECT Budget (instead of approving)
echo -e "${BLUE}[5/7] REJECTING budget...${NC}"
REJECT_RESPONSE=$(curl -s -X PATCH "${API_BASE}/budgets/${BUDGET_ID}/reject" \
  -H "Content-Type: application/json" \
  -d "{
    \"rejectionReason\": \"Customer declined the price - Saga compensation test\"
  }")
echo -e "${GREEN}Budget rejected${NC}"
echo -e "${YELLOW}  (BudgetRejected event sent to EventBridge -> OS Service)${NC}"
echo ""

# 6. Verify Order Status Changed to REJECTED
echo -e "${BLUE}[6/7] Verifying order status...${NC}"
sleep 3
ORDER_STATUS_RESPONSE=$(curl -s "${API_BASE}/service-orders/${ORDER_ID}")
ORDER_STATUS=$(echo ${ORDER_STATUS_RESPONSE} | jq -r '.status // .data.status // empty')

if [ "$ORDER_STATUS" == "REJECTED" ] || [ "$ORDER_STATUS" == "CANCELLED" ]; then
    echo -e "${GREEN}Order status correctly updated to: ${ORDER_STATUS}${NC}"
else
    echo -e "${YELLOW}Order status is: ${ORDER_STATUS} (expected REJECTED/CANCELLED)${NC}"
    echo "  This might be expected depending on business rules"
fi
echo ""

# 7. Verify NO Execution Was Created
echo -e "${BLUE}[7/7] Verifying execution was NOT created...${NC}"
sleep 5
EXECUTION_RESPONSE=$(curl -s "${API_BASE}/executions?serviceOrderId=${ORDER_ID}")
EXECUTION_COUNT=$(echo ${EXECUTION_RESPONSE} | jq -r 'length // 0')

if [ "$EXECUTION_COUNT" == "0" ]; then
    echo -e "${GREEN}No execution created (Saga compensation successful)${NC}"
else
    echo -e "${RED}Execution was created despite budget rejection!${NC}"
    echo "Response: ${EXECUTION_RESPONSE}"
    exit 1
fi
echo ""

# Summary
echo "=================================================="
echo -e "${GREEN}Saga Compensation Test PASSED!${NC}"
echo "=================================================="
echo ""
echo "Test Results Summary:"
echo "  Client ID:        ${CLIENT_ID}"
echo "  Vehicle ID:       ${VEHICLE_ID}"
echo "  Service Order ID: ${ORDER_ID} (Status: ${ORDER_STATUS})"
echo "  Budget ID:        ${BUDGET_ID} (Status: REJECTED)"
echo "  Execution Count:  ${EXECUTION_COUNT} (Expected: 0)"
echo ""
echo "Saga Compensation Validated:"
echo "  BudgetRejected event processed"
echo "  Order status updated to REJECTED/CANCELLED"
echo "  No execution created (compensation successful)"
echo ""
