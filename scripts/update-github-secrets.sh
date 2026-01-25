#!/bin/bash
# =============================================================================
# Update GitHub Secrets Across All FIAP Repositories
# =============================================================================
# Supports AWS Academy credential format (copy-paste from AWS Details page)
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

# =============================================================================
# Functions
# =============================================================================

print_header() {
    echo -e "\n${BLUE}══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}  FIAP Tech Challenge - Update GitHub Secrets${NC}"
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

get_github_owner() {
    # Auto-detect GitHub username from gh CLI
    local username=$(gh api user -q '.login' 2>/dev/null)

    if [[ -z "$username" ]]; then
        echo -e "${YELLOW}Could not auto-detect GitHub username${NC}"
        read -p "Enter your GitHub username: " username
    else
        echo -e "${GREEN}✓ GitHub user: ${username}${NC}"
    fi

    echo -e "\n${CYAN}Update secrets in:${NC}"
    echo "  1) Personal repositories (${username}/*)"
    echo "  2) Organization repositories (fiap-tech-challenge-projects/*)"
    read -p "Choice [1/2]: " owner_choice

    case $owner_choice in
        2)
            GITHUB_OWNER="fiap-tech-challenge-projects"
            echo -e "${GREEN}✓ Targeting organization: ${GITHUB_OWNER}${NC}"
            ;;
        *)
            GITHUB_OWNER="$username"
            echo -e "${GREEN}✓ Targeting personal repos: ${GITHUB_OWNER}${NC}"
            ;;
    esac
}

get_aws_academy_credentials() {
    echo -e "\n${CYAN}═══ AWS Academy Credentials ═══${NC}"
    echo -e "${YELLOW}Go to AWS Academy → AWS Details → Show (AWS CLI)${NC}"
    echo -e "${YELLOW}Then paste the credentials below (one per line):${NC}\n"

    # Method 1: Parse AWS Academy format
    echo -e "You can paste the AWS Academy format like:"
    echo -e "${CYAN}[default]"
    echo -e "aws_access_key_id=ASIA..."
    echo -e "aws_secret_access_key=..."
    echo -e "aws_session_token=...${NC}\n"

    echo -e "Or enter values individually:\n"

    read -p "AWS_ACCESS_KEY_ID: " AWS_ACCESS_KEY_ID
    read -p "AWS_SECRET_ACCESS_KEY: " AWS_SECRET_ACCESS_KEY
    read -p "AWS_SESSION_TOKEN: " AWS_SESSION_TOKEN
    read -p "AWS_ACCOUNT_ID (12 digits): " AWS_ACCOUNT_ID

    # Validate
    if [[ -z "$AWS_ACCESS_KEY_ID" || -z "$AWS_SECRET_ACCESS_KEY" || -z "$AWS_SESSION_TOKEN" ]]; then
        echo -e "${RED}Error: AWS credentials are required${NC}"
        exit 1
    fi

    if [[ -z "$AWS_ACCOUNT_ID" ]]; then
        echo -e "${YELLOW}Warning: AWS_ACCOUNT_ID not provided, will skip it${NC}"
    fi

    echo -e "\n${GREEN}✓ Credentials received${NC}"
}

parse_aws_academy_block() {
    echo -e "\n${CYAN}═══ Paste AWS Academy Credentials Block ═══${NC}"
    echo -e "${YELLOW}From AWS Academy → AWS Details → Show (AWS CLI)${NC}"
    echo -e "${YELLOW}Paste the block below, then press Enter twice:${NC}\n"

    local block=""
    local empty_lines=0

    while IFS= read -r line; do
        if [[ -z "$line" ]]; then
            ((empty_lines++))
            if [[ $empty_lines -ge 1 ]]; then
                break
            fi
        else
            empty_lines=0
            block+="$line"$'\n'
        fi
    done

    # Parse the block
    AWS_ACCESS_KEY_ID=$(echo "$block" | grep -E "^aws_access_key_id\s*=" | cut -d'=' -f2 | tr -d ' ')
    AWS_SECRET_ACCESS_KEY=$(echo "$block" | grep -E "^aws_secret_access_key\s*=" | cut -d'=' -f2 | tr -d ' ')
    AWS_SESSION_TOKEN=$(echo "$block" | grep -E "^aws_session_token\s*=" | cut -d'=' -f2 | tr -d ' ')

    if [[ -n "$AWS_ACCESS_KEY_ID" && -n "$AWS_SECRET_ACCESS_KEY" && -n "$AWS_SESSION_TOKEN" ]]; then
        echo -e "${GREEN}✓ Parsed 3 credentials from block${NC}"
        echo -e "\n${YELLOW}AWS_ACCOUNT_ID is shown at the top of AWS Details (12-digit number)${NC}"
        read -p "AWS_ACCOUNT_ID: " AWS_ACCOUNT_ID
        return 0
    fi

    return 1
}

update_repo_secrets() {
    local repo=$1
    local full_repo="${GITHUB_OWNER}/${repo}"

    echo -ne "  ${repo}... "

    # Check if repo exists
    if ! gh repo view "$full_repo" &> /dev/null 2>&1; then
        echo -e "${YELLOW}not found, skipping${NC}"
        return
    fi

    # Update secrets
    echo "$AWS_ACCESS_KEY_ID" | gh secret set AWS_ACCESS_KEY_ID -R "$full_repo" 2>/dev/null
    echo "$AWS_SECRET_ACCESS_KEY" | gh secret set AWS_SECRET_ACCESS_KEY -R "$full_repo" 2>/dev/null
    echo "$AWS_SESSION_TOKEN" | gh secret set AWS_SESSION_TOKEN -R "$full_repo" 2>/dev/null

    if [[ -n "$AWS_ACCOUNT_ID" ]]; then
        echo "$AWS_ACCOUNT_ID" | gh secret set AWS_ACCOUNT_ID -R "$full_repo" 2>/dev/null
    fi

    echo -e "${GREEN}✓${NC}"
}

# =============================================================================
# Main
# =============================================================================

print_header
check_gh_cli
get_github_owner

echo -e "\n${CYAN}How do you want to enter credentials?${NC}"
echo "  1) Enter values one by one"
echo "  2) Paste AWS Academy block"
read -p "Choice [1/2]: " choice

case $choice in
    2)
        if ! parse_aws_academy_block; then
            echo -e "${YELLOW}Could not parse block, falling back to manual entry${NC}"
            get_aws_academy_credentials
        fi
        ;;
    *)
        get_aws_academy_credentials
        ;;
esac

echo -e "\n${YELLOW}Updating secrets in ${#REPOS[@]} repositories...${NC}\n"

for repo in "${REPOS[@]}"; do
    update_repo_secrets "$repo"
done

echo -e "\n${GREEN}══════════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  All secrets updated successfully!${NC}"
echo -e "${GREEN}══════════════════════════════════════════════════════════════${NC}"
echo -e "\n${YELLOW}⚠ Remember: AWS Academy tokens expire in ~4 hours${NC}\n"
