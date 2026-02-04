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

    # Validate required credentials (session token optional for non-Academy accounts)
    if [[ -z "$AWS_ACCESS_KEY_ID" || -z "$AWS_SECRET_ACCESS_KEY" ]]; then
        echo -e "${RED}Error: AWS credentials are required${NC}"
        echo "Please provide at minimum: AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY"
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
    if ! gh repo view "$full_repo" &> /dev/null; then
        echo -e "${YELLOW}not found, skipping${NC}"
        return
    fi

    # Update secrets (suppress all output)
    echo "$AWS_ACCESS_KEY_ID" | gh secret set AWS_ACCESS_KEY_ID -R "$full_repo" &>/dev/null
    echo "$AWS_SECRET_ACCESS_KEY" | gh secret set AWS_SECRET_ACCESS_KEY -R "$full_repo" &>/dev/null

    # Only set session token if it exists (AWS Academy)
    if [[ -n "$AWS_SESSION_TOKEN" ]]; then
        echo "$AWS_SESSION_TOKEN" | gh secret set AWS_SESSION_TOKEN -R "$full_repo" &>/dev/null
    fi

    if [[ -n "$AWS_ACCOUNT_ID" ]]; then
        echo "$AWS_ACCOUNT_ID" | gh secret set AWS_ACCOUNT_ID -R "$full_repo" &>/dev/null
    fi

    echo -e "${GREEN}✓${NC}"
}

update_local_aws_credentials() {
    local aws_dir="$HOME/.aws"
    local creds_file="$aws_dir/credentials"
    local config_file="$aws_dir/config"

    echo -e "${CYAN}Updating local AWS credentials...${NC}"

    # Create .aws directory if it doesn't exist
    mkdir -p "$aws_dir"

    # Backup existing credentials
    if [[ -f "$creds_file" ]]; then
        cp "$creds_file" "${creds_file}.backup.$(date +%Y%m%d%H%M%S)"
        echo -e "  ${YELLOW}Backup created: ${creds_file}.backup.*${NC}"
    fi

    # Write credentials
    cat > "$creds_file" << EOF
[default]
aws_access_key_id = ${AWS_ACCESS_KEY_ID}
aws_secret_access_key = ${AWS_SECRET_ACCESS_KEY}
EOF

    # Add session token only if it exists (AWS Academy)
    if [[ -n "$AWS_SESSION_TOKEN" ]]; then
        echo "aws_session_token = ${AWS_SESSION_TOKEN}" >> "$creds_file"
    fi

    # Set restrictive permissions
    chmod 600 "$creds_file"

    # Update/create config file
    if [[ ! -f "$config_file" ]]; then
        cat > "$config_file" << EOF
[default]
region = us-east-1
output = json
EOF
        chmod 600 "$config_file"
    fi

    echo -e "  ${GREEN}✓ Local credentials updated: $creds_file${NC}"
    echo -e "  ${GREEN}✓ Region: us-east-1${NC}"
    if [[ -n "$AWS_ACCOUNT_ID" ]]; then
        echo -e "  ${GREEN}✓ Account ID: ${AWS_ACCOUNT_ID}${NC}"
    fi
}

# =============================================================================
# Main
# =============================================================================

load_from_env_local() {
    local env_file="./.env.local"

    if [[ ! -f "$env_file" ]]; then
        return 1
    fi

    # Source the .env.local file
    source "$env_file"

    if [[ -n "$AWS_ACCESS_KEY_ID" && -n "$AWS_SECRET_ACCESS_KEY" && -n "$AWS_ACCOUNT_ID" ]]; then
        echo -e "\n${GREEN}✓ Loaded credentials from .env.local${NC}"
        echo -e "  AWS_ACCESS_KEY_ID: ${AWS_ACCESS_KEY_ID:0:20}..."
        echo -e "  AWS_ACCOUNT_ID: ${AWS_ACCOUNT_ID}"

        read -p "Use these credentials? [Y/n]: " use_env
        if [[ "$use_env" =~ ^[Nn] ]]; then
            return 1
        fi
        return 0
    fi

    return 1
}

print_header
check_gh_cli
get_github_owner

# Try to load from .env.local first
if load_from_env_local; then
    echo -e "${GREEN}Using credentials from .env.local${NC}"
else
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
fi

# Update local AWS credentials
echo ""
update_local_aws_credentials

# Update GitHub secrets
echo -e "\n${YELLOW}Updating secrets in ${#REPOS[@]} repositories...${NC}\n"

for repo in "${REPOS[@]}"; do
    update_repo_secrets "$repo"
done

echo -e "\n${GREEN}══════════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  All credentials updated successfully!${NC}"
echo -e "${GREEN}══════════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  ✓ Local AWS credentials: ~/.aws/credentials${NC}"
echo -e "${GREEN}  ✓ GitHub secrets: ${#REPOS[@]} repositories${NC}"
echo -e "${GREEN}══════════════════════════════════════════════════════════════${NC}"

if [[ -n "$AWS_SESSION_TOKEN" ]]; then
    echo -e "\n${YELLOW}⚠ Remember: AWS Academy tokens expire in ~4 hours${NC}\n"
else
    echo -e "\n${CYAN}Using non-Academy AWS account (no session token expiration)${NC}\n"
fi
