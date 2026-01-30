#!/bin/bash
# =============================================================================
# Delete AWS_SESSION_TOKEN from All Repositories
# =============================================================================

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Repositories
REPOS=(
    "kubernetes-core-infra"
    "kubernetes-addons"
    "database-managed-infra"
    "lambda-api-handler"
    "k8s-main-service"
    "infra-orchestrator"
)

echo -e "\n${BLUE}══════════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}  Delete AWS_SESSION_TOKEN from All Repositories${NC}"
echo -e "${BLUE}══════════════════════════════════════════════════════════════${NC}\n"

# Check gh CLI
if ! command -v gh &> /dev/null; then
    echo -e "${RED}Error: GitHub CLI (gh) not found${NC}"
    echo -e "Install with: ${CYAN}brew install gh${NC}"
    exit 1
fi

if ! gh auth status &> /dev/null 2>&1; then
    echo -e "${RED}Error: Not authenticated with GitHub CLI${NC}"
    echo -e "Run: ${CYAN}gh auth login${NC}"
    exit 1
fi

# Get GitHub username
USERNAME=$(gh api user -q '.login' 2>/dev/null)
echo -e "${GREEN}✓ GitHub user: ${USERNAME}${NC}\n"

# Delete from organization repos
echo -e "${YELLOW}Deleting from Organization repos (fiap-tech-challenge-projects/*)...${NC}\n"

for repo in "${REPOS[@]}"; do
    full_repo="fiap-tech-challenge-projects/${repo}"
    echo -ne "  ${repo}... "

    if gh secret delete AWS_SESSION_TOKEN -R "$full_repo" 2>/dev/null; then
        echo -e "${GREEN}✓${NC}"
    else
        echo -e "${YELLOW}(not found or already deleted)${NC}"
    fi
done

echo ""

# Delete from personal repos
echo -e "${YELLOW}Deleting from Personal repos (${USERNAME}/*)...${NC}\n"

for repo in "${REPOS[@]}"; do
    full_repo="${USERNAME}/${repo}"
    echo -ne "  ${repo}... "

    if gh secret delete AWS_SESSION_TOKEN -R "$full_repo" 2>/dev/null; then
        echo -e "${GREEN}✓${NC}"
    else
        echo -e "${YELLOW}(not found or already deleted)${NC}"
    fi
done

echo -e "\n${GREEN}══════════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  AWS_SESSION_TOKEN deleted from all repositories!${NC}"
echo -e "${GREEN}══════════════════════════════════════════════════════════════${NC}\n"

echo -e "${BLUE}Next steps:${NC}"
echo -e "1. The workflows will now use only AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY"
echo -e "2. No session token needed for non-Academy accounts"
echo -e "3. You can now re-run the failed workflow\n"
