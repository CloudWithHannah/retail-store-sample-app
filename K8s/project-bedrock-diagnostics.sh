#!/bin/bash
#
# SAFE MODE: Infrastructure Diagnostic Script
# NO JQ REQUIRED - Uses pure bash and AWS CLI built-in parsing
#

set -o pipefail

# --- Configuration ---
EKS_CLUSTER_NAME="Project-Bedrock-EKSCluster"
LBC_ROLE_NAME="ProjectBedrock-LBC-Policy"
LBC_POLICY_NAME="lbc-policy"
LBC_SERVICE_ACCOUNT="aws-load-balancer-controller"
LBC_NAMESPACE="kube-system"
AWS_REGION="eu-north-1"
LOG_FILE="/tmp/eks-safe-diagnostic-$(date +%s).log"
BACKUP_DIR="/tmp/eks-backup-$(date +%s)"

# Safety Mode: Set to "yes" to only show what WOULD be done (dry-run)
DRY_RUN="${DRY_RUN:-no}"

# Auto-fix mode: Set to "yes" to apply all fixes without prompting (DANGEROUS)
AUTO_FIX="${AUTO_FIX:-no}"

# Backup mode: Always backup before making changes
ENABLE_BACKUPS="yes"

# Colors
C_GREEN="\033[0;32m"
C_RED="\033[0;31m"
C_YELLOW="\033[0;33m"
C_BLUE="\033[0;34m"
C_MAGENTA="\033[0;35m"
C_CYAN="\033[0;36m"
C_NONE="\033[0m"

# Global tracking
CRITICAL_ISSUES=0
WARNINGS=0
FIXES_APPLIED=0
BACKUPS_CREATED=0

# Create backup directory
mkdir -p "$BACKUP_DIR"

# Logging
exec > >(tee -a "$LOG_FILE")
exec 2>&1

echo -e "${C_MAGENTA}================================================================================================${C_NONE}"
echo -e "${C_MAGENTA}    SAFE MODE: INFRASTRUCTURE DIAGNOSTIC SCRIPT (NO JQ REQUIRED)${C_NONE}"
if [ "$DRY_RUN" == "yes" ]; then
    echo -e "${C_YELLOW}    DRY RUN MODE: No changes will be made${C_NONE}"
fi
if [ "$AUTO_FIX" == "yes" ]; then
    echo -e "${C_RED}    AUTO-FIX MODE: Changes will be applied automatically (DANGEROUS!)${C_NONE}"
fi
echo -e "${C_MAGENTA}    Logging to: $LOG_FILE${C_NONE}"
echo -e "${C_MAGENTA}    Backups to: $BACKUP_DIR${C_NONE}"
echo -e "${C_MAGENTA}================================================================================================${C_NONE}"
echo ""

# Helper functions
log_section() {
    echo -e "\n${C_CYAN}█████████████████████████████████████████████████████████████████████████████████████${C_NONE}"
    echo -e "${C_CYAN}██${C_NONE} $1"
    echo -e "${C_CYAN}█████████████████████████████████████████████████████████████████████████████████████${C_NONE}"
}

log_check() {
    echo -e "\n${C_YELLOW}[CHECK]${C_NONE} $1"
}

log_pass() {
    echo -e "  ${C_GREEN}✓ PASS:${C_NONE} $1"
}

log_fail() {
    echo -e "  ${C_RED}✗ FAIL:${C_NONE} $1"
    ((CRITICAL_ISSUES++))
}

log_warn() {
    echo -e "  ${C_YELLOW}⚠ WARN:${C_NONE} $1"
    ((WARNINGS++))
}

log_fix() {
    echo -e "  ${C_BLUE}🔧 FIX:${C_NONE} $1"
    ((FIXES_APPLIED++))
}

log_info() {
    echo -e "  ${C_CYAN}ℹ INFO:${C_NONE} $1"
}

log_backup() {
    echo -e "  ${C_GREEN}💾 BACKUP:${C_NONE} $1"
    ((BACKUPS_CREATED++))
}

log_dry_run() {
    echo -e "  ${C_YELLOW}[DRY-RUN]${C_NONE} Would execute: $1"
}

prompt_fix() {
    local message="$1"
    local danger_level="${2:-medium}"
    
    if [ "$DRY_RUN" == "yes" ]; then
        log_dry_run "$message"
        return 1
    fi
    
    if [ "$AUTO_FIX" == "yes" ]; then
        echo -e "  ${C_BLUE}[AUTO-FIX]${C_NONE} Automatically applying: $message"
        return 0
    fi
    
    local danger_emoji=""
    case "$danger_level" in
        high)
            danger_emoji="${C_RED}⚠️  HIGH RISK ⚠️${C_NONE} "
            ;;
        medium)
            danger_emoji="${C_YELLOW}⚠️  MEDIUM RISK${C_NONE} "
            ;;
        low)
            danger_emoji="${C_GREEN}✓ LOW RISK${C_NONE} "
            ;;
    esac
    
    read -p "$(echo -e "  ${danger_emoji}\n  ${C_BLUE}→ $message (y/N): "${C_NONE})" -n 1 -r
    echo
    [[ $REPLY =~ ^[Yy]$ ]]
}

backup_file() {
    local description="$1"
    local content="$2"
    local filename="$3"
    
    if [ "$ENABLE_BACKUPS" == "yes" ]; then
        echo "$content" > "${BACKUP_DIR}/${filename}"
        log_backup "$description saved to ${BACKUP_DIR}/${filename}"
    fi
}

confirm_cluster() {
    echo -e "${C_RED}================================================================================================${C_NONE}"
    echo -e "${C_RED}SAFETY CHECK: Please confirm you're working on the correct cluster${C_NONE}"
    echo -e "${C_RED}================================================================================================${C_NONE}"
    echo ""
    echo "  Cluster Name: ${C_YELLOW}$EKS_CLUSTER_NAME${C_NONE}"
    echo "  Region: ${C_YELLOW}$AWS_REGION${C_NONE}"
    echo "  AWS Account: ${C_YELLOW}$(aws sts get-caller-identity --query Account --output text 2>/dev/null)${C_NONE}"
    echo ""
    read -p "$(echo -e "${C_RED}Is this correct? Type 'yes' to continue: ${C_NONE}")" -r
    echo
    if [ "$REPLY" != "yes" ]; then
        echo -e "${C_RED}Aborted by user. Update cluster name/region at top of script.${C_NONE}"
        exit 1
    fi
}

if [ "$DRY_RUN" != "yes" ]; then
    confirm_cluster
fi

# ============================================================================
# SECTION 1: AUTHENTICATION & BASIC CHECKS
# ============================================================================
log_section "SECTION 1: AUTHENTICATION & BASIC ENVIRONMENT CHECKS"

log_check "Verifying required tools"
for tool in aws kubectl; do
    if ! command -v $tool &> /dev/null; then
        log_fail "$tool not installed!"
        exit 1
    else
        log_pass "$tool is installed"
    fi
done

log_check "Checking for eksctl (optional but helpful)"
if command -v eksctl &> /dev/null; then
    log_pass "eksctl is available"
    EKSCTL_AVAILABLE="yes"
else
    log_warn "eksctl not installed (some auto-fixes won't be available)"
    EKSCTL_AVAILABLE="no"
fi

log_check "Validating AWS authentication"
USER_ARN=$(aws sts get-caller-identity --query Arn --output text 2>/dev/null)
if [ $? -ne 0 ] || [ -z "$USER_ARN" ]; then
    log_fail "AWS authentication failed!"
    exit 1
fi

AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
log_pass "Authenticated as: $USER_ARN"
log_info "Account ID: $AWS_ACCOUNT_ID"

log_check "Testing kubectl access to cluster"
kubectl cluster-info &>/dev/null
if [ $? -ne 0 ]; then
    log_fail "kubectl cannot connect to cluster"
    log_info "Run: aws eks update-kubeconfig --name $EKS_CLUSTER_NAME --region $AWS_REGION"
    exit 1
fi
log_pass "kubectl connected to cluster"

log_check "Testing cluster admin permissions"
kubectl get nodes &>/dev/null
if [ $? -ne 0 ]; then
    log_fail "ACCESS DENIED: You don't have cluster access!"
    log_info "You must be added to aws-auth ConfigMap by the cluster creator"
    exit 1
fi
NODE_COUNT=$(kubectl get nodes --no-headers 2>/dev/null | wc -l)
log_pass "You have cluster admin access ($NODE_COUNT nodes)"

log_check "Backing up aws-auth ConfigMap"
AWS_AUTH_CM=$(kubectl get configmap aws-auth -n kube-system -o yaml 2>&1)
if [ $? -eq 0 ]; then
    backup_file "aws-auth ConfigMap" "$AWS_AUTH_CM" "aws-auth-configmap.yaml"
fi

# ============================================================================
# SECTION 2: EKS CLUSTER INFORMATION
# ============================================================================
log_section "SECTION 2: EKS CLUSTER CONFIGURATION"

log_check "Retrieving cluster information"
CLUSTER_STATUS=$(aws eks describe-cluster --name "$EKS_CLUSTER_NAME" --region "$AWS_REGION" --query "cluster.status" --output text 2>&1)

if [ $? -ne 0 ]; then
    log_fail "Cannot describe cluster '$EKS_CLUSTER_NAME' in region '$AWS_REGION'"
    echo "$CLUSTER_STATUS"
    exit 1
fi

CLUSTER_VERSION=$(aws eks describe-cluster --name "$EKS_CLUSTER_NAME" --region "$AWS_REGION" --query "cluster.version" --output text)
CLUSTER_ENDPOINT=$(aws eks describe-cluster --name "$EKS_CLUSTER_NAME" --region "$AWS_REGION" --query "cluster.endpoint" --output text)
VPC_ID=$(aws eks describe-cluster --name "$EKS_CLUSTER_NAME" --region "$AWS_REGION" --query "cluster.resourcesVpcConfig.vpcId" --output text)
CLUSTER_SG=$(aws eks describe-cluster --name "$EKS_CLUSTER_NAME" --region "$AWS_REGION" --query "cluster.resourcesVpcConfig.clusterSecurityGroupId" --output text)

log_pass "Cluster Status: $CLUSTER_STATUS"
log_info "Kubernetes Version: $CLUSTER_VERSION"
log_info "Endpoint: $CLUSTER_ENDPOINT"
log_info "VPC ID: $VPC_ID"
log_info "Security Group: $CLUSTER_SG"

# Get subnet IDs
SUBNET_IDS=$(aws eks describe-cluster --name "$EKS_CLUSTER_NAME" --region "$AWS_REGION" --query "cluster.resourcesVpcConfig.subnetIds" --output text)
log_info "Subnets: $SUBNET_IDS"

# Backup cluster info
CLUSTER_INFO_JSON=$(aws eks describe-cluster --name "$EKS_CLUSTER_NAME" --region "$AWS_REGION" --output json)
backup_file "Cluster configuration" "$CLUSTER_INFO_JSON" "cluster-info.json"

# Check K8s version compatibility
K8S_MINOR=$(echo "$CLUSTER_VERSION" | cut -d. -f2)
if [ "$K8S_MINOR" -ge 29 ]; then
    log_warn "K8s 1.29+ detected. Ensure AWS Load Balancer Controller v2.7.0+ is installed"
    log_info "K8s 1.29 requires newer LBC version for compatibility"
fi

# ============================================================================
# SECTION 3: OIDC PROVIDER (THE ROOT CAUSE CHECK)
# ============================================================================
log_section "SECTION 3: OIDC PROVIDER - THE IDENTITY BRIDGE"

log_check "Checking OIDC provider configuration"
OIDC_URL=$(aws eks describe-cluster --name "$EKS_CLUSTER_NAME" --region "$AWS_REGION" --query "cluster.identity.oidc.issuer" --output text 2>/dev/null)

if [ "$OIDC_URL" == "None" ] || [ -z "$OIDC_URL" ]; then
    log_fail "OIDC provider NOT configured!"
    log_info "THIS IS THE ROOT CAUSE of 'sts:AssumeRoleWithWebIdentity' errors!"
    
    if [ "$EKSCTL_AVAILABLE" == "yes" ]; then
        if prompt_fix "Associate OIDC provider using eksctl?" "high"; then
            if [ "$DRY_RUN" == "yes" ]; then
                log_dry_run "eksctl utils associate-iam-oidc-provider --cluster=$EKS_CLUSTER_NAME --region=$AWS_REGION --approve"
            else
                eksctl utils associate-iam-oidc-provider \
                    --cluster="$EKS_CLUSTER_NAME" \
                    --region="$AWS_REGION" \
                    --approve
                
                if [ $? -eq 0 ]; then
                    log_fix "OIDC provider associated successfully"
                    # Refresh OIDC URL
                    OIDC_URL=$(aws eks describe-cluster --name "$EKS_CLUSTER_NAME" --region "$AWS_REGION" --query "cluster.identity.oidc.issuer" --output text)
                else
                    log_fail "Failed to associate OIDC provider"
                fi
            fi
        fi
    else
        log_fail "eksctl not available. Cannot auto-fix OIDC provider."
        log_info "Install eksctl or manually create OIDC provider in IAM console"
        exit 1
    fi
fi

if [ "$OIDC_URL" != "None" ] && [ -n "$OIDC_URL" ]; then
    log_pass "OIDC Issuer URL: $OIDC_URL"
    
    OIDC_PROVIDER_ID=$(echo "$OIDC_URL" | sed 's|https://||')
    OIDC_PROVIDER_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:oidc-provider/${OIDC_PROVIDER_ID}"
    log_info "OIDC Provider ARN: $OIDC_PROVIDER_ARN"
    
    log_check "Verifying OIDC provider exists in IAM"
    OIDC_EXISTS=$(aws iam get-open-id-connect-provider --open-id-connect-provider-arn "$OIDC_PROVIDER_ARN" --query "Url" --output text 2>&1)
    
    if [ $? -ne 0 ]; then
        log_fail "OIDC provider not found in IAM!"
        echo "$OIDC_EXISTS"
        
        if [ "$EKSCTL_AVAILABLE" == "yes" ]; then
            if prompt_fix "Create OIDC provider in IAM?" "high"; then
                if [ "$DRY_RUN" == "yes" ]; then
                    log_dry_run "eksctl utils associate-iam-oidc-provider"
                else
                    eksctl utils associate-iam-oidc-provider \
                        --cluster="$EKS_CLUSTER_NAME" \
                        --region="$AWS_REGION" \
                        --approve
                    
                    if [ $? -eq 0 ]; then
                        log_fix "OIDC provider created in IAM"
                    fi
                fi
            fi
        fi
    else
        log_pass "OIDC provider exists in IAM"
        
        # Check thumbprints
        THUMBPRINTS=$(aws iam get-open-id-connect-provider --open-id-connect-provider-arn "$OIDC_PROVIDER_ARN" --query "ThumbprintList" --output text 2>/dev/null)
        log_info "OIDC Thumbprints: $THUMBPRINTS"
        
        # Check client IDs
        CLIENT_IDS=$(aws iam get-open-id-connect-provider --open-id-connect-provider-arn "$OIDC_PROVIDER_ARN" --query "ClientIDList" --output text 2>/dev/null)
        log_info "OIDC Client IDs: $CLIENT_IDS"
        
        if ! echo "$CLIENT_IDS" | grep -q "sts.amazonaws.com"; then
            log_warn "sts.amazonaws.com not in client ID list"
        fi
    fi
fi

# ============================================================================
# SECTION 4: IAM ROLE DEEP INSPECTION
# ============================================================================
log_section "SECTION 4: IAM ROLE FOR LOAD BALANCER CONTROLLER"

log_check "Searching for IAM role: $LBC_ROLE_NAME"
ROLE_ARN=$(aws iam get-role --role-name "$LBC_ROLE_NAME" --query "Role.Arn" --output text 2>&1)

if [ $? -ne 0 ]; then
    log_fail "IAM Role '$LBC_ROLE_NAME' not found!"
    
    log_info "Searching for roles with 'balancer' or 'lbc' in name..."
    POSSIBLE_ROLES=$(aws iam list-roles --query 'Roles[?contains(RoleName, `balancer`) || contains(RoleName, `lbc`) || contains(RoleName, `LBC`)].RoleName' --output text 2>/dev/null)
    
    if [ -n "$POSSIBLE_ROLES" ]; then
        log_info "Found possible roles: $POSSIBLE_ROLES"
        log_warn "Update LBC_ROLE_NAME variable at top of script with correct name"
    else
        log_info "No similar roles found"
    fi
    
    exit 1
else
    ROLE_CREATE_DATE=$(aws iam get-role --role-name "$LBC_ROLE_NAME" --query "Role.CreateDate" --output text)
    log_pass "Found IAM Role: $ROLE_ARN"
    log_info "Created: $ROLE_CREATE_DATE"
    
    # Backup role info
    ROLE_INFO_JSON=$(aws iam get-role --role-name "$LBC_ROLE_NAME" --output json)
    backup_file "IAM role configuration" "$ROLE_INFO_JSON" "iam-role-info.json"
fi

log_check "Analyzing Trust Policy (AssumeRolePolicyDocument)"
TRUST_POLICY_JSON=$(aws iam get-role --role-name "$LBC_ROLE_NAME" --query "Role.AssumeRolePolicyDocument" --output json 2>/dev/null)
backup_file "Original trust policy" "$TRUST_POLICY_JSON" "trust-policy-original.json"

# Parse trust policy using grep and sed (no jq needed)
TRUST_PRINCIPAL=$(echo "$TRUST_POLICY_JSON" | grep -oP '"Federated":\s*"\K[^"]+' | head -1)
TRUST_ACTION=$(echo "$TRUST_POLICY_JSON" | grep -oP '"Action":\s*"\K[^"]+' | head -1)

TRUST_NEEDS_FIX=0

log_check "Verifying Trust Policy Principal (Federated Identity)"
if [ -z "$TRUST_PRINCIPAL" ]; then
    log_fail "No Federated principal found in trust policy!"
    TRUST_NEEDS_FIX=1
elif [ "$TRUST_PRINCIPAL" != "$OIDC_PROVIDER_ARN" ]; then
    log_fail "Trust Policy Principal MISMATCH!"
    log_info "Expected: $OIDC_PROVIDER_ARN"
    log_info "Found: $TRUST_PRINCIPAL"
    TRUST_NEEDS_FIX=1
else
    log_pass "Trust Policy Principal is correct"
fi

log_check "Verifying Trust Policy Action"
if [ "$TRUST_ACTION" != "sts:AssumeRoleWithWebIdentity" ]; then
    log_fail "Trust Policy Action incorrect (found: $TRUST_ACTION)"
    TRUST_NEEDS_FIX=1
else
    log_pass "Trust Policy Action is correct"
fi

log_check "Verifying Trust Policy Conditions (aud + sub)"
EXPECTED_AUD_KEY="${OIDC_PROVIDER_ID}:aud"
EXPECTED_SUB_KEY="${OIDC_PROVIDER_ID}:sub"
EXPECTED_SUB_VALUE="system:serviceaccount:${LBC_NAMESPACE}:${LBC_SERVICE_ACCOUNT}"

# Check if conditions exist
if echo "$TRUST_POLICY_JSON" | grep -q "$EXPECTED_AUD_KEY"; then
    if echo "$TRUST_POLICY_JSON" | grep -q "sts.amazonaws.com"; then
        log_pass "Trust Policy 'aud' condition correct"
    else
        log_fail "Trust Policy 'aud' condition value incorrect"
        TRUST_NEEDS_FIX=1
    fi
else
    log_fail "Trust Policy missing 'aud' condition"
    TRUST_NEEDS_FIX=1
fi

if echo "$TRUST_POLICY_JSON" | grep -q "$EXPECTED_SUB_KEY"; then
    if echo "$TRUST_POLICY_JSON" | grep -q "$EXPECTED_SUB_VALUE"; then
        log_pass "Trust Policy 'sub' condition correct"
    else
        log_fail "Trust Policy 'sub' condition value incorrect"
        TRUST_NEEDS_FIX=1
    fi
else
    log_fail "Trust Policy missing 'sub' condition"
    TRUST_NEEDS_FIX=1
fi

# Fix trust policy if needed
if [ "$TRUST_NEEDS_FIX" -eq 1 ]; then
    log_check "Trust Policy needs correction"
    
    CORRECT_TRUST_POLICY=$(cat <<EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Principal": {
                "Federated": "$OIDC_PROVIDER_ARN"
            },
            "Action": "sts:AssumeRoleWithWebIdentity",
            "Condition": {
                "StringEquals": {
                    "${OIDC_PROVIDER_ID}:aud": "sts.amazonaws.com",
                    "${OIDC_PROVIDER_ID}:sub": "$EXPECTED_SUB_VALUE"
                }
            }
        }
    ]
}
EOF
)
    
    backup_file "Correct trust policy" "$CORRECT_TRUST_POLICY" "trust-policy-correct.json"
    log_info "Correct trust policy saved to backup directory"
    
    if prompt_fix "Update Trust Policy to correct configuration?" "high"; then
        if [ "$DRY_RUN" == "yes" ]; then
            log_dry_run "aws iam update-assume-role-policy --role-name $LBC_ROLE_NAME --policy-document <correct_policy>"
        else
            aws iam update-assume-role-policy \
                --role-name "$LBC_ROLE_NAME" \
                --policy-document "$CORRECT_TRUST_POLICY"
            
            if [ $? -eq 0 ]; then
                log_fix "Trust Policy updated successfully"
                log_info "Controller pods will pick up new permissions on restart"
            else
                log_fail "Failed to update Trust Policy"
            fi
        fi
    fi
fi

log_check "Checking attached managed policies"
ATTACHED_POLICY_COUNT=$(aws iam list-attached-role-policies --role-name "$LBC_ROLE_NAME" --query "AttachedPolicies" --output text 2>&1 | wc -l)

if [ $? -ne 0 ]; then
    log_fail "Cannot list attached policies"
else
    log_pass "Role has $ATTACHED_POLICY_COUNT managed policy/policies attached"
    
    # List policies
    aws iam list-attached-role-policies --role-name "$LBC_ROLE_NAME" --query "AttachedPolicies[*].[PolicyName,PolicyArn]" --output text 2>/dev/null | while read name arn; do
        log_info "  - $name ($arn)"
    done
fi

# ============================================================================
# SECTION 5: IAM PERMISSIONS POLICY
# ============================================================================
log_section "SECTION 5: IAM PERMISSIONS POLICY FOR LBC"

log_check "Searching for IAM policy: $LBC_POLICY_NAME"
LBC_POLICY_ARN=$(aws iam list-policies --scope Local --query "Policies[?PolicyName=='$LBC_POLICY_NAME'].Arn" --output text 2>/dev/null)

if [ -z "$LBC_POLICY_ARN" ]; then
    log_fail "IAM Policy '$LBC_POLICY_NAME' not found!"
    
    log_info "Searching for policies with 'balancer' or 'lbc' in name..."
    POSSIBLE_POLICIES=$(aws iam list-policies --scope Local --query 'Policies[?contains(PolicyName, `balancer`) || contains(PolicyName, `lbc`)].PolicyName' --output text 2>/dev/null)
    
    if [ -n "$POSSIBLE_POLICIES" ]; then
        log_info "Found possible policies: $POSSIBLE_POLICIES"
        log_warn "Update LBC_POLICY_NAME variable at top of script"
    fi
    
    if prompt_fix "Download and create the policy now?" "medium"; then
        if [ "$DRY_RUN" == "yes" ]; then
            log_dry_run "Download policy from AWS and create with name $LBC_POLICY_NAME"
        else
            log_info "Downloading AWS Load Balancer Controller IAM policy..."
            curl -so /tmp/lbc-iam-policy.json https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/main/docs/install/iam_policy.json
            
            if [ $? -eq 0 ]; then
                log_info "Creating policy '$LBC_POLICY_NAME'..."
                CREATE_OUTPUT=$(aws iam create-policy \
                    --policy-name "$LBC_POLICY_NAME" \
                    --policy-document file:///tmp/lbc-iam-policy.json 2>&1)
                
                if [ $? -eq 0 ]; then
                    log_fix "Policy created successfully"
                    LBC_POLICY_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:policy/${LBC_POLICY_NAME}"
                else
                    log_fail "Failed to create policy"
                    echo "$CREATE_OUTPUT"
                fi
            else
                log_fail "Failed to download policy"
            fi
        fi
    fi
else
    log_pass "Found IAM Policy: $LBC_POLICY_ARN"
    
    # Check policy version
    POLICY_VERSION=$(aws iam get-policy --policy-arn "$LBC_POLICY_ARN" --query "Policy.DefaultVersionId" --output text 2>/dev/null)
    log_info "Policy version: $POLICY_VERSION"
fi

# Check if policy is attached to role
if [ -n "$LBC_POLICY_ARN" ] && [ -n "$ROLE_ARN" ]; then
    log_check "Verifying policy is attached to role"
    IS_ATTACHED=$(aws iam list-attached-role-policies --role-name "$LBC_ROLE_NAME" --query "AttachedPolicies[?PolicyArn=='$LBC_POLICY_ARN'].PolicyArn" --output text 2>/dev/null)
    
    if [ -z "$IS_ATTACHED" ]; then
        log_fail "Policy NOT attached to role!"
        
        if prompt_fix "Attach policy to role now?" "low"; then
            if [ "$DRY_RUN" == "yes" ]; then
                log_dry_run "aws iam attach-role-policy --role-name $LBC_ROLE_NAME --policy-arn $LBC_POLICY_ARN"
            else
                aws iam attach-role-policy \
                    --role-name "$LBC_ROLE_NAME" \
                    --policy-arn "$LBC_POLICY_ARN"
                
                if [ $? -eq 0 ]; then
                    log_fix "Policy attached to role successfully"
                else
                    log_fail "Failed to attach policy"
                fi
            fi
        fi
    else
        log_pass "Policy is correctly attached to role"
    fi
fi

# ============================================================================
# SECTION 6: KUBERNETES SERVICE ACCOUNT
# ============================================================================
log_section "SECTION 6: KUBERNETES SERVICE ACCOUNT"

log_check "Checking if namespace '$LBC_NAMESPACE' exists"
kubectl get namespace "$LBC_NAMESPACE" &>/dev/null
if [ $? -ne 0 ]; then
    log_fail "Namespace '$LBC_NAMESPACE' not found!"
    
    if prompt_fix "Create namespace?" "low"; then
        if [ "$DRY_RUN" == "yes" ]; then
            log_dry_run "kubectl create namespace $LBC_NAMESPACE"
        else
            kubectl create namespace "$LBC_NAMESPACE"
            if [ $? -eq 0 ]; then
                log_fix "Namespace created"
            fi
        fi
    fi
else
    log_pass "Namespace exists"
fi

log_check "Checking ServiceAccount: $LBC_SERVICE_ACCOUNT"
kubectl get serviceaccount "$LBC_SERVICE_ACCOUNT" -n "$LBC_NAMESPACE" &>/dev/null
SA_EXISTS=$?

if [ $SA_EXISTS -ne 0 ]; then
    log_fail "ServiceAccount '$LBC_SERVICE_ACCOUNT' not found"
    
    if prompt_fix "Create ServiceAccount with IAM role annotation?" "low"; then
        if [ "$DRY_RUN" == "yes" ]; then
            log_dry_run "kubectl create serviceaccount $LBC_SERVICE_ACCOUNT -n $LBC_NAMESPACE"
            log_dry_run "kubectl annotate serviceaccount $LBC_SERVICE_ACCOUNT -n $LBC_NAMESPACE eks.amazonaws.com/role-arn=$ROLE_ARN"
        else
            kubectl create serviceaccount "$LBC_SERVICE_ACCOUNT" -n "$LBC_NAMESPACE"
            kubectl annotate serviceaccount "$LBC_SERVICE_ACCOUNT" -n "$LBC_NAMESPACE" \
                "eks.amazonaws.com/role-arn=$ROLE_ARN"
            
            if [ $? -eq 0 ]; then
                log_fix "ServiceAccount created and annotated"
            else
                log_fail "Failed to create ServiceAccount"
            fi
        fi
    fi
else
    log_pass "ServiceAccount exists"
    
    # Backup ServiceAccount
    SA_YAML=$(kubectl get serviceaccount "$LBC_SERVICE_ACCOUNT" -n "$LBC_NAMESPACE" -o yaml 2>/dev/null)
    backup_file "ServiceAccount configuration" "$SA_YAML" "serviceaccount.yaml"
    
    log_check "Verifying ServiceAccount IAM role annotation"
    SA_ROLE_ARN=$(kubectl get serviceaccount "$LBC_SERVICE_ACCOUNT" -n "$LBC_NAMESPACE" -o jsonpath='{.metadata.annotations.eks\.amazonaws\.com/role-arn}' 2>/dev/null)
    
    if [ -z "$SA_ROLE_ARN" ]; then
        log_fail "ServiceAccount missing 'eks.amazonaws.com/role-arn' annotation!"
        
        if prompt_fix "Add IAM role annotation to ServiceAccount?" "medium"; then
            if [ "$DRY_RUN" == "yes" ]; then
                log_dry_run "kubectl annotate serviceaccount $LBC_SERVICE_ACCOUNT -n $LBC_NAMESPACE eks.amazonaws.com/role-arn=$ROLE_ARN"
            else
                kubectl annotate serviceaccount "$LBC_SERVICE_ACCOUNT" -n "$LBC_NAMESPACE" \
                    "eks.amazonaws.com/role-arn=$ROLE_ARN" --overwrite
                
                if [ $? -eq 0 ]; then
                    log_fix "Annotation added to ServiceAccount"
                else
                    log_fail "Failed to add annotation"
                fi
            fi
        fi
    elif [ "$SA_ROLE_ARN" != "$ROLE_ARN" ]; then
        log_fail "ServiceAccount IAM role annotation MISMATCH!"
        log_info "Expected: $ROLE_ARN"
        log_info "Found: $SA_ROLE_ARN"
        
        if prompt_fix "Update ServiceAccount annotation to correct role?" "medium"; then
            if [ "$DRY_RUN" == "yes" ]; then
                log_dry_run "kubectl annotate serviceaccount $LBC_SERVICE_ACCOUNT -n $LBC_NAMESPACE eks.amazonaws.com/role-arn=$ROLE_ARN --overwrite"
            else
                kubectl annotate serviceaccount "$LBC_SERVICE_ACCOUNT" -n "$LBC_NAMESPACE" \
                    "eks.amazonaws.com/role-arn=$ROLE_ARN" --overwrite
                
                if [ $? -eq 0 ]; then
                    log_fix "Annotation updated"
                else
                    log_fail "Failed to update annotation"
                fi
            fi
        fi
    else
        log_pass "ServiceAccount has correct IAM role annotation"
    fi
fi

# ============================================================================
# SECTION 7: SUBNET TAGGING FOR LOAD BALANCERS
# ============================================================================
log_section "SECTION 7: SUBNET TAGGING FOR LOAD BALANCER DISCOVERY"

log_check "Verifying subnet tags required by AWS Load Balancer Controller"
log_info "Public subnets need: kubernetes.io/role/elb=1"
log_info "Private subnets need: kubernetes.io/role/internal-elb=1"

for subnet in $SUBNET_IDS; do
    log_check "Checking subnet: $subnet"
    
    # Get subnet tags
    SUBNET_TAGS=$(aws ec2 describe-subnets --subnet-ids "$subnet" --region "$AWS_REGION" --query 'Subnets[0].Tags[*].[Key,Value]' --output text 2>/dev/null)
    
    HAS_ELB_TAG=$(echo "$SUBNET_TAGS" | grep -c "kubernetes.io/role/elb")
    HAS_INTERNAL_ELB_TAG=$(echo "$SUBNET_TAGS" | grep -c "kubernetes.io/role/internal-elb")
    HAS_CLUSTER_TAG=$(echo "$SUBNET_TAGS" | grep -c "kubernetes.io/cluster/$EKS_CLUSTER_NAME")
    
    if [ "$HAS_ELB_TAG" -eq 0 ] && [ "$HAS_INTERNAL_ELB_TAG" -eq 0 ]; then
        log_fail "Subnet $subnet missing required ELB tags!"
        
        if prompt_fix "Tag subnet $subnet for public ELB (kubernetes.io/role/elb=1)?" "medium"; then
            if [ "$DRY_RUN" == "yes" ]; then
                log_dry_run "aws ec2 create-tags --resources $subnet --tags Key=kubernetes.io/role/elb,Value=1"
            else
                aws ec2 create-tags --resources "$subnet" --tags "Key=kubernetes.io/role/elb,Value=1" --region "$AWS_REGION"
                if [ $? -eq 0 ]; then
                    log_fix "Tagged subnet $subnet for public ELB"
                else
                    log_fail "Failed to tag subnet"
                fi
            fi
        fi
    else
        log_pass "Subnet has ELB role tag"
    fi
    
    if [ "$HAS_CLUSTER_TAG" -eq 0 ]; then
        log_warn "Subnet $subnet missing cluster ownership tag"
        
        if prompt_fix "Add cluster tag to subnet $subnet?" "low"; then
            if [ "$DRY_RUN" == "yes" ]; then
                log_dry_run "aws ec2 create-tags --resources $subnet --tags Key=kubernetes.io/cluster/$EKS_CLUSTER_NAME,Value=shared"
            else
                aws ec2 create-tags --resources "$subnet" --tags "Key=kubernetes.io/cluster/$EKS_CLUSTER_NAME,Value=shared" --region "$AWS_REGION"
                if [ $? -eq 0 ]; then
                    log_fix "Tagged subnet with cluster ownership"
                fi
            fi
        fi
    fi
done

# ============================================================================
# SECTION 8: AWS LOAD BALANCER CONTROLLER DEPLOYMENT
# ============================================================================
log_section "SECTION 8: AWS LOAD BALANCER CONTROLLER DEPLOYMENT"

log_check "Searching for AWS Load Balancer Controller deployment"
kubectl get deployment -n "$LBC_NAMESPACE" -l app.kubernetes.io/name=aws-load-balancer-controller &>/dev/null

if [ $? -ne 0 ]; then
    log_fail "AWS Load Balancer Controller deployment not found!"
    log_info "You need to install the AWS Load Balancer Controller"
    log_info "Install via Helm: https://kubernetes-sigs.github.io/aws-load-balancer-controller/"
    
    if command -v helm &> /dev/null; then
        if prompt_fix "Install AWS Load Balancer Controller via Helm now?" "high"; then
            if [ "$DRY_RUN" == "yes" ]; then
                log_dry_run "helm repo add eks https://aws.github.io/eks-charts"
                log_dry_run "helm install aws-load-balancer-controller eks/aws-load-balancer-controller"
            else
                log_info "Adding EKS Helm repository..."
                helm repo add eks https://aws.github.io/eks-charts 2>/dev/null
                helm repo update
                
                log_info "Installing aws-load-balancer-controller..."
                helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
                    -n "$LBC_NAMESPACE" \
                    --set clusterName="$EKS_CLUSTER_NAME" \
                    --set serviceAccount.create=false \
                    --set serviceAccount.name="$LBC_SERVICE_ACCOUNT" \
                    --set region="$AWS_REGION" \
                    --set vpcId="$VPC_ID"
                
                if [ $? -eq 0 ]; then
                    log_fix "AWS Load Balancer Controller installed"
                    sleep 10
                else
                    log_fail "Failed to install controller"
                fi
            fi
        fi
    else
        log_warn "Helm not installed. Cannot auto-install controller."
        log_info "Install manually: https://kubernetes-sigs.github.io/aws-load-balancer-controller/latest/deploy/installation/"
    fi
else
    DEPLOYMENT_NAME=$(kubectl get deployment -n "$LBC_NAMESPACE" -l app.kubernetes.io/name=aws-load-balancer-controller -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    log_pass "Found deployment: $DEPLOYMENT_NAME"
    
    log_check "Checking deployment status"
    DESIRED_REPLICAS=$(kubectl get deployment "$DEPLOYMENT_NAME" -n "$LBC_NAMESPACE" -o jsonpath='{.spec.replicas}')
    READY_REPLICAS=$(kubectl get deployment "$DEPLOYMENT_NAME" -n "$LBC_NAMESPACE" -o jsonpath='{.status.readyReplicas}')
    
    if [ -z "$READY_REPLICAS" ]; then
        READY_REPLICAS=0
    fi
    
    log_info "Replicas: $READY_REPLICAS/$DESIRED_REPLICAS"
    
    if [ "$READY_REPLICAS" -lt "$DESIRED_REPLICAS" ]; then
        log_fail "Not all replicas are ready!"
    else
        log_pass "All replicas are ready"
    fi
    
    log_check "Checking controller version"
    CONTROLLER_IMAGE=$(kubectl get deployment "$DEPLOYMENT_NAME" -n "$LBC_NAMESPACE" -o jsonpath='{.spec.template.spec.containers[0].image}')
    log_info "Controller image: $CONTROLLER_IMAGE"
    
    CONTROLLER_VERSION=$(echo "$CONTROLLER_IMAGE" | grep -oP 'v\d+\.\d+\.\d+' || echo "unknown")
    log_info "Controller version: $CONTROLLER_VERSION"
    
    if [ "$K8S_MINOR" -ge 29 ]; then
        CONTROLLER_MINOR=$(echo "$CONTROLLER_VERSION" | cut -d. -f2 2>/dev/null)
        if [ ! -z "$CONTROLLER_MINOR" ] && [ "$CONTROLLER_MINOR" -lt 7 ] 2>/dev/null; then
            log_fail "Controller version $CONTROLLER_VERSION may be incompatible with K8s 1.29!"
            log_warn "AWS LBC v2.7.0+ is required for K8s 1.29+"
        else
            log_pass "Controller version compatible with K8s $CLUSTER_VERSION"
        fi
    fi
    
    log_check "Verifying deployment uses correct ServiceAccount"
    DEPLOYMENT_SA=$(kubectl get deployment "$DEPLOYMENT_NAME" -n "$LBC_NAMESPACE" -o jsonpath='{.spec.template.spec.serviceAccountName}')
    
    if [ "$DEPLOYMENT_SA" != "$LBC_SERVICE_ACCOUNT" ]; then
        log_fail "Deployment using wrong ServiceAccount!"
        log_info "Expected: $LBC_SERVICE_ACCOUNT"
        log_info "Found: $DEPLOYMENT_SA"
        
        if prompt_fix "Patch deployment to use correct ServiceAccount?" "high"; then
            if [ "$DRY_RUN" == "yes" ]; then
                log_dry_run "kubectl patch deployment $DEPLOYMENT_NAME -n $LBC_NAMESPACE"
            else
                kubectl patch deployment "$DEPLOYMENT_NAME" -n "$LBC_NAMESPACE" \
                    -p "{\"spec\":{\"template\":{\"spec\":{\"serviceAccountName\":\"$LBC_SERVICE_ACCOUNT\"}}}}"
                
                if [ $? -eq 0 ]; then
                    log_fix "Deployment patched - pods will restart"
                fi
            fi
        fi
    else
        log_pass "Deployment uses correct ServiceAccount"
    fi
fi

# ============================================================================
# SECTION 9: CONTROLLER POD ANALYSIS
# ============================================================================
log_section "SECTION 9: CONTROLLER POD RUNTIME ANALYSIS"

log_check "Finding AWS Load Balancer Controller pods"
POD_NAMES=$(kubectl get pods -n "$LBC_NAMESPACE" -l app.kubernetes.io/name=aws-load-balancer-controller -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)

if [ -z "$POD_NAMES" ]; then
    log_fail "No controller pods found!"
else
    POD_COUNT=$(echo "$POD_NAMES" | wc -w)
    log_pass "Found $POD_COUNT controller pod(s)"
    
    for pod_name in $POD_NAMES; do
        log_check "Analyzing pod: $pod_name"
        
        POD_STATUS=$(kubectl get pod "$pod_name" -n "$LBC_NAMESPACE" -o jsonpath='{.status.phase}')
        log_info "Pod status: $POD_STATUS"
        
        if [ "$POD_STATUS" != "Running" ]; then
            log_fail "Pod is not Running!"
            
            log_info "Recent pod events:"
            kubectl get events -n "$LBC_NAMESPACE" --field-selector involvedObject.name="$pod_name" --sort-by='.lastTimestamp' 2>/dev/null | tail -10
        else
            log_pass "Pod is Running"
        fi
        
        CONTAINER_READY=$(kubectl get pod "$pod_name" -n "$LBC_NAMESPACE" -o jsonpath='{.status.containerStatuses[0].ready}')
        RESTART_COUNT=$(kubectl get pod "$pod_name" -n "$LBC_NAMESPACE" -o jsonpath='{.status.containerStatuses[0].restartCount}')
        
        if [ "$CONTAINER_READY" != "true" ]; then
            log_fail "Container not ready!"
        else
            log_pass "Container is ready"
        fi
        
        log_info "Restart count: $RESTART_COUNT"
        
        if [ "$RESTART_COUNT" -gt 0 ]; then
            log_warn "Pod has restarted $RESTART_COUNT times"
        fi
        
        log_check "Checking pod logs for errors (last 100 lines)"
        RECENT_LOGS=$(kubectl logs "$pod_name" -n "$LBC_NAMESPACE" --tail=100 2>&1)
        
        if echo "$RECENT_LOGS" | grep -qi "AccessDenied"; then
            log_fail "Found 'AccessDenied' errors in logs!"
            echo "$RECENT_LOGS" | grep -i "AccessDenied" | head -5
        fi
        
        if echo "$RECENT_LOGS" | grep -qi "AssumeRoleWithWebIdentity"; then
            log_fail "Found 'AssumeRoleWithWebIdentity' errors!"
            echo "$RECENT_LOGS" | grep -i "AssumeRoleWithWebIdentity" | head -5
        fi
        
        if echo "$RECENT_LOGS" | grep -qi "InvalidClientTokenId\|WebIdentityErr"; then
            log_fail "Found authentication errors - OIDC/IAM mismatch!"
            echo "$RECENT_LOGS" | grep -iE "InvalidClientTokenId|WebIdentityErr" | head -5
        fi
        
        if echo "$RECENT_LOGS" | grep -qi "error"; then
            ERROR_COUNT=$(echo "$RECENT_LOGS" | grep -ci "error")
            log_warn "Found $ERROR_COUNT error messages in logs"
            echo "$RECENT_LOGS" | grep -i "error" | head -5
        else
            log_pass "No obvious errors in recent logs"
        fi
        
        kubectl logs "$pod_name" -n "$LBC_NAMESPACE" --tail=500 > "${BACKUP_DIR}/lbc-pod-${pod_name}.log" 2>&1
        log_info "Pod logs saved to ${BACKUP_DIR}/lbc-pod-${pod_name}.log"
        
        if [ "$POD_STATUS" == "Running" ]; then
            log_check "Testing AWS credentials from inside pod"
            
            TOKEN_FILE=$(kubectl exec "$pod_name" -n "$LBC_NAMESPACE" -- printenv AWS_WEB_IDENTITY_TOKEN_FILE 2>/dev/null)
            if [ -n "$TOKEN_FILE" ]; then
                log_pass "AWS_WEB_IDENTITY_TOKEN_FILE is set: $TOKEN_FILE"
            else
                log_fail "AWS_WEB_IDENTITY_TOKEN_FILE not set in pod!"
            fi
            
            POD_ROLE_ARN=$(kubectl exec "$pod_name" -n "$LBC_NAMESPACE" -- printenv AWS_ROLE_ARN 2>/dev/null)
            if [ -n "$POD_ROLE_ARN" ]; then
                log_info "AWS_ROLE_ARN in pod: $POD_ROLE_ARN"
                
                if [ "$POD_ROLE_ARN" != "$ROLE_ARN" ]; then
                    log_fail "AWS_ROLE_ARN in pod doesn't match expected role!"
                    log_info "Expected: $ROLE_ARN"
                fi
            else
                log_fail "AWS_ROLE_ARN not set in pod!"
            fi
        fi
    done
fi

# ============================================================================
# SECTION 10: INGRESS CLASS
# ============================================================================
log_section "SECTION 10: INGRESS CLASS CONFIGURATION"

log_check "Checking for 'alb' IngressClass"
kubectl get ingressclass alb &>/dev/null

if [ $? -ne 0 ]; then
    log_fail "IngressClass 'alb' not found!"
    
    if prompt_fix "Create 'alb' IngressClass?" "low"; then
        if [ "$DRY_RUN" == "yes" ]; then
            log_dry_run "kubectl apply -f <alb-ingressclass.yaml>"
        else
            cat <<EOF | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: IngressClass
metadata:
  name: alb
spec:
  controller: ingress.k8s.aws/alb
EOF
            
            if [ $? -eq 0 ]; then
                log_fix "IngressClass 'alb' created"
            fi
        fi
    fi
else
    log_pass "IngressClass 'alb' exists"
    
    CONTROLLER_NAME=$(kubectl get ingressclass alb -o jsonpath='{.spec.controller}')
    log_info "Controller: $CONTROLLER_NAME"
    
    if [ "$CONTROLLER_NAME" != "ingress.k8s.aws/alb" ]; then
        log_warn "IngressClass controller name unexpected: $CONTROLLER_NAME"
    fi
fi

# ============================================================================
# SECTION 11: INGRESS RESOURCES
# ============================================================================
log_section "SECTION 11: INGRESS RESOURCES ANALYSIS"

log_check "Listing all Ingress resources"
INGRESS_LIST=$(kubectl get ingress --all-namespaces --no-headers 2>/dev/null)

if [ -z "$INGRESS_LIST" ]; then
    log_warn "No ingress resources found"
else
    INGRESS_COUNT=$(echo "$INGRESS_LIST" | wc -l)
    log_info "Found $INGRESS_COUNT ingress resource(s)"
    
    echo "$INGRESS_LIST" | while read namespace name class hosts address ports age; do
        log_check "Analyzing ingress: $namespace/$name"
        
        INGRESS_CLASS=$(kubectl get ingress "$name" -n "$namespace" -o jsonpath='{.spec.ingressClassName}' 2>/dev/null)
        if [ -z "$INGRESS_CLASS" ]; then
            INGRESS_CLASS=$(kubectl get ingress "$name" -n "$namespace" -o jsonpath='{.metadata.annotations.kubernetes\.io/ingress\.class}' 2>/dev/null)
        fi
        
        log_info "IngressClass: ${INGRESS_CLASS:-none}"
        
        if [ "$INGRESS_CLASS" != "alb" ]; then
            log_warn "Ingress not using 'alb' class - controller won't process it"
        fi
        
        LB_HOSTNAME=$(kubectl get ingress "$name" -n "$namespace" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null)
        
        if [ -n "$LB_HOSTNAME" ]; then
            log_pass "Ingress has load balancer: $LB_HOSTNAME"
        else
            log_fail "Ingress has NO load balancer address - THIS IS THE PROBLEM!"
        fi
        
        log_info "Recent events for ingress $name:"
        kubectl get events -n "$namespace" --field-selector involvedObject.name="$name" --sort-by='.lastTimestamp' 2>/dev/null | tail -5
    done
fi

# ============================================================================
# SECTION 12: FINAL VERIFICATION CHECKLIST
# ============================================================================
log_section "SECTION 12: FINAL VERIFICATION CHECKLIST"

CHECKLIST_PASS=0
CHECKLIST_TOTAL=10

echo ""
log_info "Running final verification checklist..."
echo ""

# Check 1: OIDC Provider
((CHECKLIST_TOTAL++))
if [ -n "$OIDC_PROVIDER_ARN" ] && aws iam get-open-id-connect-provider --open-id-connect-provider-arn "$OIDC_PROVIDER_ARN" &>/dev/null; then
    log_pass "[1/10] OIDC Provider exists in IAM"
    ((CHECKLIST_PASS++))
else
    log_fail "[1/10] OIDC Provider missing"
fi

# Check 2: IAM Role
((CHECKLIST_TOTAL++))
if [ -n "$ROLE_ARN" ]; then
    log_pass "[2/10] IAM Role exists"
    ((CHECKLIST_PASS++))
else
    log_fail "[2/10] IAM Role missing"
fi

# Check 3: Trust Policy
((CHECKLIST_TOTAL++))
if [ "${TRUST_NEEDS_FIX:-0}" -eq 0 ]; then
    log_pass "[3/10] Trust Policy correctly configured"
    ((CHECKLIST_PASS++))
else
    log_fail "[3/10] Trust Policy has issues"
fi

# Check 4: Policy attached
((CHECKLIST_TOTAL++))
if [ -n "$IS_ATTACHED" ]; then
    log_pass "[4/10] Permissions Policy attached"
    ((CHECKLIST_PASS++))
else
    log_fail "[4/10] Permissions Policy not attached"
fi

# Check 5: ServiceAccount exists
((CHECKLIST_TOTAL++))
if kubectl get serviceaccount "$LBC_SERVICE_ACCOUNT" -n "$LBC_NAMESPACE" &>/dev/null; then
    log_pass "[5/10] ServiceAccount exists"
    ((CHECKLIST_PASS++))
else
    log_fail "[5/10] ServiceAccount missing"
fi

# Check 6: ServiceAccount annotation
((CHECKLIST_TOTAL++))
SA_CHECK_ARN=$(kubectl get serviceaccount "$LBC_SERVICE_ACCOUNT" -n "$LBC_NAMESPACE" -o jsonpath='{.metadata.annotations.eks\.amazonaws\.com/role-arn}' 2>/dev/null)
if [ "$SA_CHECK_ARN" == "$ROLE_ARN" ]; then
    log_pass "[6/10] ServiceAccount annotation correct"
    ((CHECKLIST_PASS++))
else
    log_fail "[6/10] ServiceAccount annotation incorrect"
fi

# Check 7: Controller deployment
((CHECKLIST_TOTAL++))
if kubectl get deployment -n "$LBC_NAMESPACE" -l app.kubernetes.io/name=aws-load-balancer-controller &>/dev/null; then
    log_pass "[7/10] Controller deployment exists"
    ((CHECKLIST_PASS++))
else
    log_fail "[7/10] Controller deployment missing"
fi

# Check 8: Pods running
((CHECKLIST_TOTAL++))
RUNNING_COUNT=$(kubectl get pods -n "$LBC_NAMESPACE" -l app.kubernetes.io/name=aws-load-balancer-controller --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l)
if [ "$RUNNING_COUNT" -gt 0 ]; then
    log_pass "[8/10] Controller pods running ($RUNNING_COUNT pod(s))"
    ((CHECKLIST_PASS++))
else
    log_fail "[8/10] No running controller pods"
fi

# Check 9: IngressClass
((CHECKLIST_TOTAL++))
if kubectl get ingressclass alb &>/dev/null; then
    log_pass "[9/10] IngressClass 'alb' exists"
    ((CHECKLIST_PASS++))
else
    log_fail "[9/10] IngressClass missing"
fi

# Check 10: Subnets tagged
((CHECKLIST_TOTAL++))
TAGGED_COUNT=0
for subnet in $SUBNET_IDS; do
    if aws ec2 describe-subnets --subnet-ids "$subnet" --region "$AWS_REGION" --query 'Subnets[0].Tags[?Key==`kubernetes.io/role/elb` || Key==`kubernetes.io/role/internal-elb`]' --output text 2>/dev/null | grep -q "kubernetes.io/role"; then
        ((TAGGED_COUNT++))
    fi
done
if [ "$TAGGED_COUNT" -gt 0 ]; then
    log_pass "[10/10] Subnets properly tagged ($TAGGED_COUNT subnet(s))"
    ((CHECKLIST_PASS++))
else
    log_fail "[10/10] No subnets tagged for ELB"
fi

echo ""
log_info "=========================================="
log_info "VERIFICATION SCORE: $CHECKLIST_PASS/10"
log_info "=========================================="

# ============================================================================
# SECTION 13: DIAGNOSTIC SUMMARY AND RECOMMENDATIONS
# ============================================================================
log_section "SECTION 13: DIAGNOSTIC SUMMARY"

echo ""
echo "================================================================================================"
echo -e "${C_MAGENTA}DIAGNOSTIC COMPLETE${C_NONE}"
echo "================================================================================================"
echo ""
echo -e "${C_YELLOW}SUMMARY:${C_NONE}"
echo "  Critical Issues Found: $CRITICAL_ISSUES"
echo "  Warnings: $WARNINGS"
echo "  Fixes Applied: $FIXES_APPLIED"
echo "  Backups Created: $BACKUPS_CREATED"
echo "  Verification Score: $CHECKLIST_PASS/10"
echo ""
echo -e "${C_YELLOW}FILES:${C_NONE}"
echo "  Log File: $LOG_FILE"
echo "  Backup Directory: $BACKUP_DIR"
echo ""

if [ "$CRITICAL_ISSUES" -eq 0 ] && [ "$CHECKLIST_PASS" -ge 8 ]; then
    echo -e "${C_GREEN}✓✓✓ NO CRITICAL ISSUES DETECTED! ✓✓✓${C_NONE}"
    echo ""
    echo "Your infrastructure appears to be correctly configured."
    echo ""
    echo "If Ingress still doesn't have a load balancer:"
    echo "  1. Wait 2-3 minutes (ALB creation takes time)"
    echo "  2. Restart controller: kubectl rollout restart deployment -n $LBC_NAMESPACE aws-load-balancer-controller"
    echo "  3. Check logs: kubectl logs -n $LBC_NAMESPACE -l app.kubernetes.io/name=aws-load-balancer-controller"
    echo ""
else
    echo -e "${C_RED}✗✗✗ FOUND $CRITICAL_ISSUES CRITICAL ISSUE(S) ✗✗✗${C_NONE}"
    echo ""
    echo "Review all FAIL items above and apply the suggested fixes."
    echo ""
    
    if [ "$TRUST_NEEDS_FIX" -eq 1 ]; then
        echo -e "${C_RED}→ CRITICAL: Trust Policy misconfigured${C_NONE}"
        echo "  Fix: Run this script again and approve trust policy update"
        echo ""
    fi
    
    if [ "$OIDC_URL" == "None" ] || [ -z "$OIDC_URL" ]; then
        echo -e "${C_RED}→ CRITICAL: OIDC Provider missing${C_NONE}"
        echo "  Fix: eksctl utils associate-iam-oidc-provider --cluster=$EKS_CLUSTER_NAME --region=$AWS_REGION --approve"
        echo ""
    fi
    
    if kubectl get pods -n "$LBC_NAMESPACE" -l app.kubernetes.io/name=aws-load-balancer-controller 2>/dev/null | grep -q "CrashLoopBackOff\|Error"; then
        echo -e "${C_RED}→ CRITICAL: Controller pods failing${C_NONE}"
        echo "  Fix: Check pod logs and ensure IAM role is correct"
        echo ""
    fi
fi

echo "================================================================================================"
echo -e "${C_CYAN}RECOMMENDED NEXT STEPS:${C_NONE}"
echo "================================================================================================"
echo ""
echo "# Monitor ingress creation:"
echo "kubectl get ingress -A --watch"
echo ""
echo "# Check controller logs in real-time:"
echo "kubectl logs -n $LBC_NAMESPACE -l app.kubernetes.io/name=aws-load-balancer-controller -f"
echo ""
echo "# Restart controller to pick up IAM changes:"
echo "kubectl rollout restart deployment -n $LBC_NAMESPACE aws-load-balancer-controller"
echo ""
echo "# Check AWS load balancers:"
echo "aws elbv2 describe-load-balancers --region $AWS_REGION --query 'LoadBalancers[?contains(LoadBalancerName, \`k8s-\`)].{Name:LoadBalancerName,DNS:DNSName,State:State.Code}' --output table"
echo ""
echo "# Describe an ingress to see detailed events:"
echo "kubectl describe ingress <ingress-name> -n <namespace>"
echo ""
echo "================================================================================================"
echo -e "${C_MAGENTA}If issues persist after fixes, check:${C_NONE}"
echo "  - AWS service quotas (Load Balancer limits)"
echo "  - VPC DNS settings (enableDnsHostnames and enableDnsSupport must be true)"
echo "  - Security group rules allowing ALB health checks"
echo "  - Controller version compatibility with K8s version"
echo "================================================================================================"
echo ""

if [ "$DRY_RUN" == "yes" ]; then
    echo -e "${C_YELLOW}NOTE: This was a DRY RUN. No changes were made.${C_NONE}"
    echo "Run without DRY_RUN=yes to apply fixes."
    echo ""
fi

exit 0
