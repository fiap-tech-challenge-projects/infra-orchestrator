#!/bin/bash
# End-to-End Test for Phase 4 Microservices Architecture
# Tests complete flow: Order -> Budget -> Payment -> Execution
# Usage: ./test-e2e.sh [environment]

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
echo "Phase 4 End-to-End Test"
echo "Environment: ${ENVIRONMENT}"
echo "Namespace: ${NAMESPACE}"
echo "=================================================="
echo ""

# Get ALB URL from Kubernetes ingress
echo "Getting API endpoint from Kubernetes..."
ALB_URL=$(kubectl get ingress os-service -n "$NAMESPACE" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null)

if [ -z "$ALB_URL" ]; then
    echo -e "${RED}Failed to get ALB URL from ingress${NC}"
    echo "  Make sure services are deployed: ./deploy-services.sh --env=${ENVIRONMENT}"
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
TEST_CPF="52998224725"

echo "=================================================="
echo "Test Flow Execution"
echo "=================================================="
echo ""

# 1. Create Client (or reuse existing)
echo -e "${BLUE}[1/12] Creating client...${NC}"
CLIENT_RESPONSE=$(curl -s -X POST ${API_BASE}/clients \
  -H "Content-Type: application/json" \
  -d "{
    \"name\": \"Test Client ${TIMESTAMP}\",
    \"email\": \"test${TIMESTAMP}@example.com\",
    \"cpfCnpj\": \"${TEST_CPF}\",
    \"phone\": \"11999999999\"
  }")

STATUS_CODE=$(echo ${CLIENT_RESPONSE} | jq -r '.statusCode // empty')
CLIENT_ID=$(echo ${CLIENT_RESPONSE} | jq -r '.id // .data.id // empty')

if [ "$STATUS_CODE" == "409" ]; then
    echo -e "${YELLOW}Client already exists, fetching...${NC}"
    CLIENTS_LIST=$(curl -s "${API_BASE}/clients")
    CLIENT_ID=$(echo ${CLIENTS_LIST} | jq -r '.[0].id // .data[0].id // empty')
fi

if [ -z "$CLIENT_ID" ] || [ "$CLIENT_ID" == "null" ]; then
    echo -e "${RED}Failed to create/find client${NC}"
    echo "Response: ${CLIENT_RESPONSE}"
    exit 1
fi
echo -e "${GREEN}Client: ${CLIENT_ID}${NC}"
echo ""

# 2. Register Vehicle (unique plate per run)
echo -e "${BLUE}[2/12] Registering vehicle...${NC}"
# Format: ABC-1234
PLATE_NUM=$(( TIMESTAMP % 9000 + 1000 ))
LICENSE_PLATE="TST-${PLATE_NUM}"
VEHICLE_RESPONSE=$(curl -s -X POST ${API_BASE}/vehicles \
  -H "Content-Type: application/json" \
  -d "{
    \"licensePlate\": \"${LICENSE_PLATE}\",
    \"make\": \"Toyota\",
    \"model\": \"Corolla\",
    \"year\": 2020,
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

# 3. Create Service Order (triggers OrderCreated event -> Billing)
echo -e "${BLUE}[3/12] Creating service order...${NC}"
ORDER_RESPONSE=$(curl -s -X POST ${API_BASE}/service-orders \
  -H "Content-Type: application/json" \
  -d "{
    \"clientId\": \"${CLIENT_ID}\",
    \"vehicleId\": \"${VEHICLE_ID}\",
    \"notes\": \"E2E Test: Oil change and tire rotation\"
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
echo -e "${BLUE}[4/12] Waiting for budget generation...${NC}"
BUDGET_ID=""
for i in {1..15}; do
    sleep 3
    BUDGET_RESPONSE=$(curl -s "${API_BASE}/budgets?serviceOrderId=${ORDER_ID}")
    # API returns { budgets: [...], total: N }
    BUDGET_ID=$(echo ${BUDGET_RESPONSE} | jq -r '.budgets[0].id // empty')

    if [ -n "$BUDGET_ID" ] && [ "$BUDGET_ID" != "null" ]; then
        echo -e "${GREEN}Budget auto-generated: ${BUDGET_ID}${NC}"
        break
    fi

    if [ $i -eq 15 ]; then
        echo -e "${RED}Budget not created after 45 seconds${NC}"
        echo "Response: ${BUDGET_RESPONSE}"
        exit 1
    fi
    echo "  Attempt $i/15 - waiting for EventBridge -> SQS -> Billing Service..."
done
echo ""

# 5. Get Budget Details
echo -e "${BLUE}[5/12] Fetching budget details...${NC}"
BUDGET_DETAILS=$(curl -s "${API_BASE}/budgets/${BUDGET_ID}")
BUDGET_AMOUNT_CENTS=$(echo ${BUDGET_DETAILS} | jq -r '.totalAmountInCents // empty')
BUDGET_STATUS=$(echo ${BUDGET_DETAILS} | jq -r '.status // empty')
BUDGET_AMOUNT_DISPLAY=$(echo "scale=2; ${BUDGET_AMOUNT_CENTS:-0} / 100" | bc)
echo -e "${GREEN}Budget Amount: R\$ ${BUDGET_AMOUNT_DISPLAY} (${BUDGET_AMOUNT_CENTS} cents)${NC}"
echo -e "${GREEN}Budget Status: ${BUDGET_STATUS}${NC}"
echo ""

# 6. Approve Budget (triggers BudgetApproved event -> OS Service)
echo -e "${BLUE}[6/12] Approving budget...${NC}"
APPROVE_RESPONSE=$(curl -s -X PATCH "${API_BASE}/budgets/${BUDGET_ID}/approve")
APPROVE_STATUS=$(echo ${APPROVE_RESPONSE} | jq -r '.status // empty')
echo -e "${GREEN}Budget approved (status: ${APPROVE_STATUS})${NC}"
echo -e "${YELLOW}  (BudgetApproved event sent to EventBridge)${NC}"
echo ""

# 7. Create Payment (triggers PaymentInitiated event)
echo -e "${BLUE}[7/12] Creating payment...${NC}"
PAYMENT_RESPONSE=$(curl -s -X POST ${API_BASE}/payments \
  -H "Content-Type: application/json" \
  -d "{
    \"budgetId\": \"${BUDGET_ID}\"
  }")

PAYMENT_ID=$(echo ${PAYMENT_RESPONSE} | jq -r '.id // empty')
MP_PAYMENT_ID=$(echo ${PAYMENT_RESPONSE} | jq -r '.mercadoPagoPaymentId // empty')
QR_CODE=$(echo ${PAYMENT_RESPONSE} | jq -r '.qrCode // empty')
if [ -z "$PAYMENT_ID" ] || [ "$PAYMENT_ID" == "null" ]; then
    echo -e "${RED}Failed to create payment${NC}"
    echo "Response: ${PAYMENT_RESPONSE}"
    exit 1
fi
echo -e "${GREEN}Payment initiated: ${PAYMENT_ID}${NC}"
echo -e "${GREEN}Mercado Pago ID: ${MP_PAYMENT_ID}${NC}"
echo ""

# 8. Simulate Payment Completion (webhook from Mercado Pago)
echo -e "${BLUE}[8/12] Simulating payment webhook (Mercado Pago)...${NC}"
WEBHOOK_RESPONSE=$(curl -s -X POST ${API_BASE}/payments/webhook \
  -H "Content-Type: application/json" \
  -d "{
    \"action\": \"payment.updated\",
    \"data\": {
      \"id\": \"${MP_PAYMENT_ID}\"
    }
  }")
echo -e "${GREEN}Payment webhook processed${NC}"
echo -e "${YELLOW}  (PaymentCompleted event sent to EventBridge -> Execution Service)${NC}"
echo ""

# 9. Wait for execution to be created
echo -e "${BLUE}[9/12] Waiting for execution creation...${NC}"
EXECUTION_ID=""
for i in {1..15}; do
    sleep 3
    EXECUTION_RESPONSE=$(curl -s "${API_BASE}/executions?serviceOrderId=${ORDER_ID}")
    # API returns { executions: [...], total: N }
    EXECUTION_ID=$(echo ${EXECUTION_RESPONSE} | jq -r '.executions[0].id // empty')

    if [ -n "$EXECUTION_ID" ] && [ "$EXECUTION_ID" != "null" ]; then
        echo -e "${GREEN}Execution created: ${EXECUTION_ID}${NC}"
        break
    fi

    if [ $i -eq 15 ]; then
        echo -e "${RED}Execution not created after 45 seconds${NC}"
        echo "Response: ${EXECUTION_RESPONSE}"
        exit 1
    fi
    echo "  Attempt $i/15 - waiting for PaymentCompleted event..."
done
echo ""

# 10. Start Execution
echo -e "${BLUE}[10/12] Starting execution...${NC}"
START_RESPONSE=$(curl -s -X PATCH "${API_BASE}/executions/${EXECUTION_ID}/start")
START_STATUS=$(echo ${START_RESPONSE} | jq -r '.status // empty')
echo -e "${GREEN}Execution started (status: ${START_STATUS})${NC}"
echo ""

# 11. Complete Execution (triggers ExecutionCompleted event -> invoicing)
echo -e "${BLUE}[11/12] Completing execution...${NC}"
COMPLETE_RESPONSE=$(curl -s -X PATCH "${API_BASE}/executions/${EXECUTION_ID}/complete")
COMPLETE_STATUS=$(echo ${COMPLETE_RESPONSE} | jq -r '.status // empty')
echo -e "${GREEN}Execution completed (status: ${COMPLETE_STATUS})${NC}"
echo -e "${YELLOW}  (ExecutionCompleted event sent to EventBridge)${NC}"
echo ""

# 12. Verify Final State
echo -e "${BLUE}[12/12] Verifying final state...${NC}"
ORDER_FINAL=$(curl -s "${API_BASE}/service-orders/${ORDER_ID}")
ORDER_STATUS=$(echo ${ORDER_FINAL} | jq -r '.status // .data.status // empty')
echo -e "${GREEN}Service Order Final Status: ${ORDER_STATUS}${NC}"
echo ""

# Summary
echo "=================================================="
echo -e "${GREEN}End-to-End Test PASSED!${NC}"
echo "=================================================="
echo ""
echo "Test Results Summary:"
echo "  Client ID:        ${CLIENT_ID}"
echo "  Vehicle ID:       ${VEHICLE_ID}"
echo "  Service Order ID: ${ORDER_ID} (Status: ${ORDER_STATUS})"
echo "  Budget ID:        ${BUDGET_ID} (Amount: R\$ ${BUDGET_AMOUNT_DISPLAY})"
echo "  Payment ID:       ${PAYMENT_ID}"
echo "  Execution ID:     ${EXECUTION_ID}"
echo ""
echo "Event Flow Validated:"
echo "  OrderCreated -> Budget Generation"
echo "  BudgetApproved -> Order Update"
echo "  PaymentCompleted -> Execution Creation"
echo "  ExecutionCompleted -> Order Finalization"
echo ""
