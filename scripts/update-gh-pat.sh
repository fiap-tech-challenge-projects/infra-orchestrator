#!/bin/bash
# =============================================================================
# Update GH_PAT Secret Across All FIAP Repositories
# =============================================================================
# Reads GH_PAT from .env.local and updates it in all GitHub repos
# =============================================================================

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Repositories to update
REPOS=(
    "kubernetes-core-infra"
    "kubernetes-addons"
    "database-managed-infra"
    "lambda-api-handler"
    "k8s-main-service"
    "infra-orchestrator"
)

GITHUB_OWNER="fiap-tech-challenge-projects"

# =============================================================================
# Functions
# =============================================================================

print_header() {
    echo -e "\n${BLUE}══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}  Update GH_PAT Secret${NC}"
    echo -e "${BLUE}══════════════════════════════════════════════════════════════${NC}\n"
}

check_gh_cli() {
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

    echo -e "${GREEN}✓ GitHub CLI authenticated${NC}"
}

load_token() {
    local env_file="$(dirname "$0")/../.env.local"

    if [[ ! -f "$env_file" ]]; then
        echo -e "${RED}Error: .env.local not found at: $env_file${NC}"
        echo -e "Create it with: ${CYAN}GH_PAT=your_token_here${NC}"
        exit 1
    fi

    # Read GH_PAT from .env.local
    GH_PAT=$(grep "^GH_PAT=" "$env_file" | cut -d'=' -f2- | tr -d ' ')

    if [[ -z "$GH_PAT" ]]; then
        echo -e "${RED}Error: GH_PAT not found in .env.local${NC}"
        exit 1
    fi

    echo -e "${GREEN}✓ GH_PAT loaded from .env.local${NC}"
}

update_repo_secret() {
    local repo=$1
    local full_repo="${GITHUB_OWNER}/${repo}"

    echo -ne "  ${repo}... "

    # Check if repo exists
    if ! gh repo view "$full_repo" &> /dev/null 2>&1; then
        echo -e "${YELLOW}not found, skipping${NC}"
        return
    fi

    # Update secret
    echo "$GH_PAT" | gh secret set GH_PAT -R "$full_repo" 2>/dev/null

    echo -e "${GREEN}✓${NC}"
}

# =============================================================================
# Main
# =============================================================================

print_header
check_gh_cli
load_token

echo -e "\n${YELLOW}Updating GH_PAT in ${#REPOS[@]} repositories...${NC}\n"

for repo in "${REPOS[@]}"; do
    update_repo_secret "$repo"
done

echo -e "\n${GREEN}══════════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  GH_PAT updated in all repositories!${NC}"
echo -e "${GREEN}══════════════════════════════════════════════════════════════${NC}\n"
