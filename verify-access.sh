#!/usr/bin/env bash
# Evidence for the Head of Security. Run as an admin. The IAM policy simulator
# evaluates attached permission boundaries, so results reflect real access.
# Never prints secret values. Fill evidence/Evidence-Report-Template.md from
# the output.
#
# Every name comes from the stack outputs of templates/onboarding.yaml and
# git-sync/connection-and-roles.yaml, so the evidence always matches Git.
#   STACK            onboarding stack name (default: found from s3-user)
#   BOOTSTRAP_STACK  Git sync bootstrap stack (default: onward-gitsync-bootstrap)
set -euo pipefail
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-eu-west-1}"   # where both stacks live
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
STACK=${STACK:-$(aws cloudformation describe-stack-resources --physical-resource-id s3-user \
  --query 'StackResources[0].StackName' --output text)}
BOOTSTRAP_STACK=${BOOTSTRAP_STACK:-onward-gitsync-bootstrap}

out() {  # out <stack> <OutputKey>  ->  value, or empty if the output is absent
  local v
  v=$(aws cloudformation describe-stacks --stack-name "$1" \
    --query "Stacks[0].Outputs[?OutputKey=='$2'].OutputValue | [0]" --output text)
  [ "$v" = "None" ] && v=""
  echo "$v"
}

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
AUDITOR_ROLE=$(out "$STACK" ExternalAuditorRoleName)
AUDITOR_ROLE_ARN=$(out "$STACK" ExternalAuditorRoleArn)
AUDIT_BUCKET=$(out "$STACK" AuditBucketName)
BUDGET=$(out "$STACK" MonthlyBudgetName)
ADMIN_ARN=arn:aws:iam::aws:policy/AdministratorAccess

sim() {  # sim <principal-arn> <action>...   (resource: *)
  local arn=$1; shift
  echo ">>> ${arn##*/}"
  aws iam simulate-principal-policy \
    --policy-source-arn "$arn" \
    --action-names "$@" \
    --query 'EvaluationResults[].[EvalActionName,EvalDecision]' --output table
}
sim_on() {  # sim_on <principal-arn> <resource-arn> <action>...
  local arn=$1 res=$2; shift 2
  echo ">>> ${arn##*/} on ${res}"
  aws iam simulate-principal-policy \
    --policy-source-arn "$arn" --resource-arns "$res" \
    --action-names "$@" \
    --query 'EvaluationResults[].[EvalActionName,EvalDecision]' --output table
}
user_arn() { echo "arn:aws:iam::${ACCOUNT}:user/$1"; }

# Section 2 grants AdministratorAccess. Remove it however the script exits,
# so a failed run can never leave the on-call engineer over-privileged.
revert_stress_test() {
  aws iam detach-group-policy --group-name "$OBS_GROUP" --policy-arn "$ADMIN_ARN" 2>/dev/null || true
  aws iam detach-user-policy --user-name "$EC2_USER_2" --policy-arn "$ADMIN_ARN" 2>/dev/null || true
}
trap revert_stress_test EXIT

echo "Account: ${ACCOUNT}   Environment: ${ENV}   Stack: ${STACK}   Run at: $(date -u +%Y-%m-%dT%H:%M:%SZ)"

echo "===== 1. Day-one access: each engineer can do their job, and no more ====="
sim "$(user_arn "$S3_USER")" s3:ListAllMyBuckets ec2:RunInstances ec2:DescribeInstances
sim_on "$(user_arn "$S3_USER")" "arn:aws:s3:::onward-${ENV}-example-bucket/*" s3:PutObject s3:GetObject
if [ -n "$AUDIT_BUCKET" ]; then
  echo "Audit evidence is off-limits even to storage engineers (expect explicitDeny):"
  sim_on "$(user_arn "$S3_USER")" "arn:aws:s3:::${AUDIT_BUCKET}/*" s3:PutObject s3:DeleteObject
fi
sim "$(user_arn "$EC2_USER_1")" ec2:RunInstances ec2:TerminateInstances ec2:DescribeInstances s3:PutObject
sim "$(user_arn "$EC2_USER_2")" ec2:DescribeInstances ec2:RunInstances ec2:TerminateInstances s3:PutObject

echo "===== 2. Stress test: loosen ${EC2_USER_2}'s group AND user to Administrator ====="
aws iam attach-group-policy --group-name "$OBS_GROUP" --policy-arn "$ADMIN_ARN"
aws iam attach-user-policy --user-name "$EC2_USER_2" --policy-arn "$ADMIN_ARN"
sleep 10   # IAM is eventually consistent
sim "$(user_arn "$EC2_USER_2")" ec2:RunInstances ec2:TerminateInstances ec2:StartInstances \
  autoscaling:CreateAutoScalingGroup iam:DeleteUserPermissionsBoundary ec2:DescribeInstances

echo "===== 3. Revert the stress test ====="
revert_stress_test
echo "Policies still attached (AdministratorAccess must not appear):"
aws iam list-attached-group-policies --group-name "$OBS_GROUP" \
  --query 'AttachedPolicies[].PolicyName' --output text
aws iam list-attached-user-policies --user-name "$EC2_USER_2" \
  --query 'AttachedPolicies[].PolicyName' --output text

# The trail includes global service events, so IAM changes are also written
# to the audit bucket in eu-west-1 if event history here comes back empty.
echo "===== 4. Who changed access, and when (eu-west-1) ====="
sleep 60   # CloudTrail event history can lag a few minutes; rerun if empty
for evt in AttachGroupPolicy AttachUserPolicy DetachGroupPolicy DetachUserPolicy CreateUser; do
  aws cloudtrail lookup-events --region eu-west-1 \
    --lookup-attributes AttributeKey=EventName,AttributeValue=$evt \
    --max-results 5 \
    --query 'Events[].[EventTime,Username,EventName]' --output table
done

echo "===== 5. Boundaries attached as defined in Git ====="
echo "Expected (from stack outputs):"
for k in StorageBoundaryArn ComputeBoundaryArn ObserverBoundaryArn; do
  echo "  $k = $(out "$STACK" $k)"
done
echo "Actual:"
for u in "${USERS[@]}"; do
  aws iam get-user --user-name "$u" \
    --query '[User.UserName, User.PermissionsBoundary.PermissionsBoundaryArn]' --output text
done

echo "===== 6. No inline policies on any user or group (expect 0) ====="
for u in "${USERS[@]}"; do
  echo "user  $u: $(aws iam list-user-policies --user-name "$u" --query 'length(PolicyNames)')"
done
for g in "${GROUPS_[@]}"; do
  echo "group $g: $(aws iam list-group-policies --group-name "$g" --query 'length(PolicyNames)')"
done

echo "===== 7. Secure first login: forced reset, no access keys, generated secret ====="
for i in "${!USERS[@]}"; do
  u=${USERS[$i]}
  aws iam get-login-profile --user-name "$u" \
    --query '[LoginProfile.UserName, LoginProfile.PasswordResetRequired]' --output text
  echo "access keys: $(aws iam list-access-keys --user-name "$u" --query 'length(AccessKeyMetadata)')"
  # describe-secret returns metadata only, never the password
  aws secretsmanager describe-secret --secret-id "${SECRETS[$i]}" \
    --query '[Name, CreatedDate]' --output text
done

echo "===== 8. Outside parties: temporary, read-only role ====="
aws iam get-role --role-name "$AUDITOR_ROLE" \
  --query '[Role.RoleName, Role.MaxSessionDuration, Role.PermissionsBoundary.PermissionsBoundaryArn]' --output text
echo "Trust policy condition (External ID required):"
aws iam get-role --role-name "$AUDITOR_ROLE" \
  --query 'Role.AssumeRolePolicyDocument.Statement[].Condition' --output json
sim "$AUDITOR_ROLE_ARN" cloudtrail:LookupEvents iam:ListUsers \
  ec2:DescribeInstances s3:GetObject secretsmanager:GetSecretValue ec2:RunInstances iam:CreateUser

echo "===== 9. Spend visible from day one ====="
aws budgets describe-budget --account-id "$ACCOUNT" --budget-name "$BUDGET" \
  --query 'Budget.[BudgetName, BudgetLimit.Amount, BudgetLimit.Unit, TimeUnit]' --output text
aws budgets describe-notifications-for-budget --account-id "$ACCOUNT" --budget-name "$BUDGET" \
  --query 'Notifications[].[NotificationType, ComparisonOperator, Threshold]' --output table

echo "===== 10. Deployed by CloudFormation Git sync, wired to the bootstrap ====="
CONNECTION_ARN=$(out "$BOOTSTRAP_STACK" ConnectionArn)
GITSYNC_ROLE_ARN=$(out "$BOOTSTRAP_STACK" GitSyncRoleArn)
DEPLOY_ROLE_ARN=$(out "$BOOTSTRAP_STACK" StackDeployRoleArn)
check() {  # check <label> <expected> <actual>
  if [ "$2" = "$3" ]; then echo "PASS  $1: $3"; else echo "FAIL  $1: expected '$2', got '$3'"; fi
}
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
