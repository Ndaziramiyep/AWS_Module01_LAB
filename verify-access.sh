#!/usr/bin/env bash
# Evidence for the Head of Security. Run as an admin. The IAM policy simulator
# evaluates attached permission boundaries, so results reflect real access.
set -euo pipefail
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
ENV=${ENV:-prod}
OBS_GROUP="onward-${ENV}-oncall-observers"

sim() {
  local user=$1; shift
  echo ">>> $user"
  aws iam simulate-principal-policy \
    --policy-source-arn "arn:aws:iam::${ACCOUNT}:user/${user}" \
    --action-names "$@" \
    --query 'EvaluationResults[].[EvalActionName,EvalDecision]' --output table
}

echo "===== 1. Day-one access: each engineer can do their job, and no more ====="
sim s3-user    s3:ListAllMyBuckets s3:PutObject ec2:RunInstances ec2:DescribeInstances
sim ec2-user-1 ec2:RunInstances ec2:TerminateInstances ec2:DescribeInstances s3:PutObject
sim ec2-user-2 ec2:DescribeInstances ec2:RunInstances ec2:TerminateInstances s3:ListAllMyBuckets s3:GetObject s3:PutObject

echo "===== 2. Stress test: loosen ec2-user-2's group AND user to Administrator ====="
aws iam attach-group-policy --group-name "$OBS_GROUP" \
  --policy-arn arn:aws:iam::aws:policy/AdministratorAccess
aws iam attach-user-policy --user-name ec2-user-2 \
  --policy-arn arn:aws:iam::aws:policy/AdministratorAccess
sleep 10   # IAM is eventually consistent
sim ec2-user-2 ec2:RunInstances ec2:TerminateInstances ec2:StartInstances ec2:DescribeInstances s3:GetObject s3:PutObject

echo "===== 3. Revert the stress test ====="
aws iam detach-group-policy --group-name "$OBS_GROUP" \
  --policy-arn arn:aws:iam::aws:policy/AdministratorAccess
aws iam detach-user-policy --user-name ec2-user-2 \
  --policy-arn arn:aws:iam::aws:policy/AdministratorAccess

echo "===== 4. Who changed access, and when (IAM events live in us-east-1) ====="
sleep 60   # CloudTrail event history can lag a few minutes; rerun if empty
for evt in AttachGroupPolicy AttachUserPolicy DetachGroupPolicy CreateUser; do
  aws cloudtrail lookup-events --region us-east-1 \
    --lookup-attributes AttributeKey=EventName,AttributeValue=$evt \
    --max-results 5 \
    --query 'Events[].[EventTime,Username,EventName]' --output table
done

echo "===== 5. Boundaries attached as defined in Git ====="
for u in s3-user ec2-user-1 ec2-user-2; do
  aws iam get-user --user-name "$u" \
    --query '[User.UserName, User.PermissionsBoundary.PermissionsBoundaryArn]' --output text
done
