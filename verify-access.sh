#!/usr/bin/env bash
# Evidence for the Head of Security. Run as an admin from the repo root:
#   ./verify-access.sh | tee evidence/verify-access-$(date +%Y%m%d).txt
# The IAM policy simulator evaluates attached permission boundaries, so the
# results reflect real access. No secret values are ever printed.
set -euo pipefail
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
ENV=${ENV:-prod}
OBS_GROUP="onward-${ENV}-oncall-observers"
AUDITOR_ROLE="onward-${ENV}-external-auditor"
EXTERNAL_ID=${EXTERNAL_ID:-onward-prod-external-audit}
ADMIN_ARN=arn:aws:iam::aws:policy/AdministratorAccess

sim() {
  local arn=$1; shift
  echo ">>> $arn"
  aws iam simulate-principal-policy --policy-source-arn "$arn" \
    --action-names "$@" \
    --query 'EvaluationResults[].[EvalActionName,EvalDecision]' --output table
}
user() { echo "arn:aws:iam::${ACCOUNT}:user/$1"; }

# Always undo the stress test, even if a later command fails.
revert() {
  aws iam detach-group-policy --group-name "$OBS_GROUP" --policy-arn "$ADMIN_ARN" 2>/dev/null || true
  aws iam detach-user-policy --user-name ec2-user-2 --policy-arn "$ADMIN_ARN" 2>/dev/null || true
}
trap revert EXIT

echo "===== 1. Day-one access: each engineer can do their job, and no more ====="
echo "Expect: S3 allowed; EC2 denied"
sim "$(user s3-user)"    s3:ListAllMyBuckets s3:PutObject ec2:RunInstances ec2:DescribeInstances
echo "Expect: EC2 allowed; S3 denied"
sim "$(user ec2-user-1)" ec2:RunInstances ec2:TerminateInstances ec2:DescribeInstances s3:PutObject
echo "Expect: only Describe allowed; create/terminate and all S3 data access denied"
sim "$(user ec2-user-2)" ec2:DescribeInstances ec2:RunInstances ec2:TerminateInstances s3:ListAllMyBuckets s3:GetObject s3:PutObject

echo "===== 2. Stress test: attach AdministratorAccess to ec2-user-2's group AND user ====="
aws iam attach-group-policy --group-name "$OBS_GROUP" --policy-arn "$ADMIN_ARN"
aws iam attach-user-policy  --user-name ec2-user-2    --policy-arn "$ADMIN_ARN"
sleep 10   # IAM is eventually consistent
aws iam list-attached-group-policies --group-name "$OBS_GROUP" --output table
aws iam list-attached-user-policies  --user-name ec2-user-2    --output table
echo "Expect: create/start/terminate STILL denied, and removing the boundary denied"
sim "$(user ec2-user-2)" ec2:RunInstances ec2:TerminateInstances ec2:StartInstances \
  autoscaling:CreateAutoScalingGroup iam:DeleteUserPermissionsBoundary ec2:DescribeInstances

echo "===== 3. Revert the stress test ====="
revert
aws iam list-attached-user-policies --user-name ec2-user-2 --output table

echo "===== 4. Who changed access, and when (CloudTrail; IAM events live in us-east-1) ====="
sleep 60   # CloudTrail event history can lag a few minutes; rerun if empty
for evt in CreateUser AttachGroupPolicy AttachUserPolicy DetachGroupPolicy DetachUserPolicy; do
  aws cloudtrail lookup-events --region us-east-1 \
    --lookup-attributes AttributeKey=EventName,AttributeValue=$evt \
    --max-results 5 \
    --query 'Events[].[EventTime,Username,EventName]' --output table
done
aws cloudtrail get-trail-status --name "onward-${ENV}-access-audit" --region us-east-1 \
  --query '{IsLogging:IsLogging,LatestDelivery:LatestDeliveryTime}' --output table 2>/dev/null \
  || echo "(trail is not in us-east-1 - check the stack Region)"

echo "===== 5. How access was defined, and who approved each change (Git history) ====="
git log --date=iso --format='%h  %ad  %an  %s' -- templates/ onboarding-deployment.yaml git-sync/

echo "===== 6. Boundaries attached and no inline policies anywhere ====="
for u in s3-user ec2-user-1 ec2-user-2; do
  echo "$u  boundary=$(aws iam get-user --user-name "$u" --query User.PermissionsBoundary.PermissionsBoundaryArn --output text)" \
       " groups=$(aws iam list-groups-for-user --user-name "$u" --query 'Groups[].GroupName' --output text)" \
       " inline=$(aws iam list-user-policies --user-name "$u" --query 'length(PolicyNames)')"
done
for g in storage-engineers compute-engineers oncall-observers; do
  echo "onward-${ENV}-$g  inline=$(aws iam list-group-policies --group-name "onward-${ENV}-$g" --query 'length(PolicyNames)')"
done

echo "===== 7. Secure first login: generated secret + forced reset (values never shown) ====="
for u in s3-user ec2-user-1 ec2-user-2; do
  echo "$u  reset_required=$(aws iam get-login-profile --user-name "$u" --query LoginProfile.PasswordResetRequired --output text 2>/dev/null || echo 'already-changed')" \
       " secret=$(aws secretsmanager describe-secret --secret-id "onward/${ENV}/onboarding/$u" --query Name --output text)" \
       " access_keys=$(aws iam list-access-keys --user-name "$u" --query 'length(AccessKeyMetadata)')"
done

echo "===== 8. Outside parties: temporary, limited role access ====="
aws iam get-role --role-name "$AUDITOR_ROLE" \
  --query 'Role.{MaxSessionSeconds:MaxSessionDuration,Boundary:PermissionsBoundary.PermissionsBoundaryArn}' --output table
echo "Expect: audit reads allowed; data, secrets and changes denied"
sim "arn:aws:iam::${ACCOUNT}:role/${AUDITOR_ROLE}" cloudtrail:LookupEvents iam:ListUsers \
  s3:GetObject secretsmanager:GetSecretValue iam:CreateUser ec2:RunInstances
echo "Session credentials expire automatically:"
aws sts assume-role --role-arn "arn:aws:iam::${ACCOUNT}:role/${AUDITOR_ROLE}" \
  --role-session-name verify-access --external-id "$EXTERNAL_ID" \
  --query 'Credentials.Expiration' --output text || echo "(caller may lack sts:AssumeRole)"
echo "Expect: assuming WITHOUT the external ID is refused:"
aws sts assume-role --role-arn "arn:aws:iam::${ACCOUNT}:role/${AUDITOR_ROLE}" \
  --role-session-name verify-no-id --query 'Credentials.Expiration' --output text 2>&1 | tail -1 || true

echo "===== 9. Spend visible from day one ====="
aws budgets describe-budgets --account-id "$ACCOUNT" \
  --query 'Budgets[].[BudgetName,BudgetLimit.Amount,CalculatedSpend.ActualSpend.Amount]' --output table

echo "===== 10. Rebuildable from the repository (stack managed by Git sync) ====="
aws cloudformation describe-stacks \
  --query "Stacks[?Tags[?Key=='ManagedBy' && Value=='cloudformation-gitsync']].[StackName,StackStatus,LastUpdatedTime]" \
  --output table
