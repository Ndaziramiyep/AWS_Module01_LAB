#!/usr/bin/env bash
# ============================================================================
# verify-access.sh - evidence for the Head of Security.
#
# What:   Proves the deployed account matches what Git defines in
#         templates/onboarding.yaml and git-sync/connection-and-roles.yaml.
# Run:    As an admin, from the repo root, in Git Bash with AWS CLI v2:
#           mkdir -p evidence
#           ./verify-access.sh | tee evidence/verify-access-$(date +%Y%m%d).txt
#         Then fill in evidence/Evidence-Report-Template.md from the output.
# Names:  Every name is read from the stack outputs, never typed here.
#           STACK            onboarding stack (default: found from s3-user)
#           BOOTSTRAP_STACK  bootstrap stack (default: onward-gitsync-bootstrap)
# Safety: Never prints secret values. The temporary AdministratorAccess from
#         section 2 is always removed, even if the script stops early.
# Note:   The IAM policy simulator evaluates attached permission boundaries,
#         so results reflect real access.
# ============================================================================
set -euo pipefail
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-eu-west-1}"   # where both stacks live
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
STACK=${STACK:-$(aws cloudformation describe-stack-resources --physical-resource-id s3-user \
  --query 'StackResources[0].StackName' --output text)}
BOOTSTRAP_STACK=${BOOTSTRAP_STACK:-onward-gitsync-bootstrap}

# ---- Helpers ---------------------------------------------------------------

# out <stack> <OutputKey>: print one stack output, or nothing if it is absent.
out() {
  local v
  v=$(aws cloudformation describe-stacks --stack-name "$1" \
    --query "Stacks[0].Outputs[?OutputKey=='$2'].OutputValue | [0]" --output text)
  [ "$v" = "None" ] && v=""
  echo "$v"
}

# sim <principal-arn> <action>...: ask the IAM simulator allowed/denied per action.
sim() {
  local arn=$1; shift
  echo ">>> ${arn##*/}"
  aws iam simulate-principal-policy \
    --policy-source-arn "$arn" \
    --action-names "$@" \
    --query 'EvaluationResults[].[EvalActionName,EvalDecision]' --output table
}

# user_arn <name>: full ARN of an IAM user in this account.
user_arn() { echo "arn:aws:iam::${ACCOUNT}:user/$1"; }

# check <label> <expected> <actual>: print PASS or FAIL for one comparison.
check() {
  if [ "$2" = "$3" ]; then echo "PASS  $1: $3"; else echo "FAIL  $1: expected '$2', got '$3'"; fi
}

# ---- Names from templates/onboarding.yaml Outputs --------------------------

ENV=$(out "$STACK" Environment)
if [ -z "$ENV" ]; then
  echo "Stack ${STACK} has no 'Environment' output. Merge the current templates/onboarding.yaml" >&2
  echo "to main and let Git sync finish, then rerun." >&2
  exit 1
fi
S3_USER=$(out "$STACK" S3UserName)
EC2_USER_1=$(out "$STACK" Ec2User1Name)
EC2_USER_2=$(out "$STACK" Ec2User2Name)
OBS_GROUP=$(out "$STACK" OnCallObserversGroupName)
USERS=("$S3_USER" "$EC2_USER_1" "$EC2_USER_2")
GROUPS_=("$(out "$STACK" StorageEngineersGroupName)" "$(out "$STACK" ComputeEngineersGroupName)" "$OBS_GROUP")
SECRETS=("$(out "$STACK" S3UserSecretArn)" "$(out "$STACK" Ec2User1SecretArn)" "$(out "$STACK" Ec2User2SecretArn)")
ADMIN_ARN=arn:aws:iam::aws:policy/AdministratorAccess

# revert_stress_test: remove the AdministratorAccess added in section 2.
# Runs on every exit, so a failed run never leaves ec2-user-2 over-privileged.
revert_stress_test() {
  aws iam detach-group-policy --group-name "$OBS_GROUP" --policy-arn "$ADMIN_ARN" 2>/dev/null || true
  aws iam detach-user-policy --user-name "$EC2_USER_2" --policy-arn "$ADMIN_ARN" 2>/dev/null || true
}
trap revert_stress_test EXIT

echo "Account: ${ACCOUNT}   Region: ${AWS_DEFAULT_REGION}   Environment: ${ENV}   Stack: ${STACK}"
echo "Run at: $(date -u +%Y-%m-%dT%H:%M:%SZ)"

# ---- 1. Day-one access: in-role actions allowed, everything else denied ----
echo "===== 1. Day-one access: each engineer can do their job, and no more ====="
sim "$(user_arn "$S3_USER")"    s3:ListAllMyBuckets s3:PutObject ec2:RunInstances ec2:DescribeInstances
sim "$(user_arn "$EC2_USER_1")" ec2:RunInstances ec2:TerminateInstances ec2:DescribeInstances s3:PutObject
sim "$(user_arn "$EC2_USER_2")" ec2:DescribeInstances ec2:RunInstances ec2:TerminateInstances s3:PutObject

# ---- 2. Stress test: AdministratorAccess cannot beat the observer boundary --
echo "===== 2. Stress test: loosen ${EC2_USER_2}'s group AND user to Administrator ====="
aws iam attach-group-policy --group-name "$OBS_GROUP" --policy-arn "$ADMIN_ARN"
aws iam attach-user-policy --user-name "$EC2_USER_2" --policy-arn "$ADMIN_ARN"
sleep 10   # IAM is eventually consistent
sim "$(user_arn "$EC2_USER_2")" ec2:RunInstances ec2:TerminateInstances ec2:StartInstances \
  autoscaling:CreateAutoScalingGroup iam:DeleteUserPermissionsBoundary ec2:DescribeInstances

# ---- 3. Revert: the test leaves no extra access behind ---------------------
echo "===== 3. Revert the stress test ====="
revert_stress_test
echo "Policies still attached (AdministratorAccess must not appear):"
aws iam list-attached-group-policies --group-name "$OBS_GROUP" \
  --query 'AttachedPolicies[].PolicyName' --output text
aws iam list-attached-user-policies --user-name "$EC2_USER_2" \
  --query 'AttachedPolicies[].PolicyName' --output text

# ---- 4. Audit trail: who changed access, and when --------------------------
# The trail (AuditTrail) includes global service events, so IAM changes are
# also written to the audit bucket in eu-west-1 if event history here is empty.
echo "===== 4. Who changed access, and when (eu-west-1) ====="
sleep 60   # CloudTrail event history can lag a few minutes; rerun if empty
for evt in AttachGroupPolicy AttachUserPolicy DetachGroupPolicy DetachUserPolicy CreateUser; do
  aws cloudtrail lookup-events --region eu-west-1 \
    --lookup-attributes AttributeKey=EventName,AttributeValue=$evt \
    --max-results 5 \
    --query 'Events[].[EventTime,Username,EventName]' --output table
done

# ---- 5. Boundaries: the ones attached are the ones defined in Git ----------
echo "===== 5. Boundaries attached as defined in Git ====="
check "${S3_USER} boundary" "$(out "$STACK" StorageBoundaryArn)" \
  "$(aws iam get-user --user-name "$S3_USER" --query 'User.PermissionsBoundary.PermissionsBoundaryArn' --output text)"
check "${EC2_USER_1} boundary" "$(out "$STACK" ComputeBoundaryArn)" \
  "$(aws iam get-user --user-name "$EC2_USER_1" --query 'User.PermissionsBoundary.PermissionsBoundaryArn' --output text)"
check "${EC2_USER_2} boundary" "$(out "$STACK" ObserverBoundaryArn)" \
  "$(aws iam get-user --user-name "$EC2_USER_2" --query 'User.PermissionsBoundary.PermissionsBoundaryArn' --output text)"

# ---- 6. No inline policies: access comes only from reviewed policies -------
echo "===== 6. No inline policies on any user or group (expect 0) ====="
for u in "${USERS[@]}"; do
  check "inline policies on user ${u}" 0 "$(aws iam list-user-policies --user-name "$u" --query 'length(PolicyNames)')"
done
for g in "${GROUPS_[@]}"; do
  check "inline policies on group ${g}" 0 "$(aws iam list-group-policies --group-name "$g" --query 'length(PolicyNames)')"
done

# ---- 7. Secure first login: forced reset, no keys, generated secret --------
echo "===== 7. Secure first login: forced reset, no access keys, generated secret ====="
for i in "${!USERS[@]}"; do
  u=${USERS[$i]}
  aws iam get-login-profile --user-name "$u" \
    --query '[LoginProfile.UserName, LoginProfile.PasswordResetRequired]' --output text
  check "access keys for ${u}" 0 "$(aws iam list-access-keys --user-name "$u" --query 'length(AccessKeyMetadata)')"
  # describe-secret returns metadata only, never the password
  aws secretsmanager describe-secret --secret-id "${SECRETS[$i]}" \
    --query '[Name, CreatedDate]' --output text
done

# ---- 8. Git sync: live stack wired to git-sync/connection-and-roles.yaml ---
echo "===== 8. Deployed by CloudFormation Git sync, wired to the bootstrap ====="
CONNECTION_ARN=$(out "$BOOTSTRAP_STACK" ConnectionArn)
GITSYNC_ROLE_ARN=$(out "$BOOTSTRAP_STACK" GitSyncRoleArn)
DEPLOY_ROLE_ARN=$(out "$BOOTSTRAP_STACK" StackDeployRoleArn)
aws cloudformation describe-stacks --stack-name "$STACK" \
  --query 'Stacks[0].[StackName, StackStatus, LastUpdatedTime]' --output text
check "Git connection status" AVAILABLE \
  "$(aws codeconnections get-connection --connection-arn "$CONNECTION_ARN" \
     --query 'Connection.ConnectionStatus' --output text)"
check "Stack service role" "$DEPLOY_ROLE_ARN" \
  "$(aws cloudformation describe-stacks --stack-name "$STACK" --query 'Stacks[0].RoleARN' --output text)"
SYNC=$(aws codeconnections get-sync-configuration --sync-type CFN_STACK_SYNC --resource-name "$STACK" \
  --query 'SyncConfiguration.[RoleArn, Branch, ConfigFile, RepositoryName]' --output text 2>/dev/null) \
  || SYNC="none"
read -r SYNC_ROLE SYNC_BRANCH SYNC_FILE SYNC_REPO <<<"$SYNC"
check "Git sync role" "$GITSYNC_ROLE_ARN" "$SYNC_ROLE"
check "Git sync branch" main "${SYNC_BRANCH:-}"
check "Git sync deployment file" onboarding-deployment.yaml "${SYNC_FILE:-}"
echo "Repository: ${SYNC_REPO:-unknown}"
