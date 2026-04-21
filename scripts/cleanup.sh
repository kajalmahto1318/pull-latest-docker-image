#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# Cleanup: delete all AWS resources created by setup-infra.sh
# Usage: ./cleanup.sh
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail
: "${AWS_REGION:=us-east-1}"
PROJECT="bluegreen"

echo "⚠️  This will DELETE all $PROJECT resources. Press Ctrl+C to abort."
read -rp "Type 'yes' to confirm: " CONFIRM
[ "$CONFIRM" != "yes" ] && echo "Cancelled" && exit 0

echo "Deleting ASGs..."
for COLOR in blue green; do
  aws autoscaling delete-auto-scaling-group \
    --auto-scaling-group-name "${PROJECT}-asg-${COLOR}" --force-delete \
    --region "$AWS_REGION" 2>/dev/null || true
done

echo "Deleting Launch Template..."
aws ec2 delete-launch-template --launch-template-name "${PROJECT}-lt" \
  --region "$AWS_REGION" 2>/dev/null || true

echo "Deleting ALB..."
ALB_ARN=$(aws elbv2 describe-load-balancers --names "${PROJECT}-alb" \
  --query "LoadBalancers[0].LoadBalancerArn" --output text --region "$AWS_REGION" 2>/dev/null || echo "")
if [ -n "$ALB_ARN" ] && [ "$ALB_ARN" != "None" ]; then
  # Delete listeners first
  LISTENERS=$(aws elbv2 describe-listeners --load-balancer-arn "$ALB_ARN" \
    --query "Listeners[].ListenerArn" --output text --region "$AWS_REGION" 2>/dev/null || echo "")
  for L in $LISTENERS; do
    aws elbv2 delete-listener --listener-arn "$L" --region "$AWS_REGION" 2>/dev/null || true
  done
  aws elbv2 delete-load-balancer --load-balancer-arn "$ALB_ARN" --region "$AWS_REGION"
fi

echo "Waiting for ALB deletion..."
sleep 30

echo "Deleting Target Groups..."
for COLOR in blue green; do
  for APP in app1 app2; do
    TG_ARN=$(aws elbv2 describe-target-groups --names "${PROJECT}-${APP}-${COLOR}" \
      --query "TargetGroups[0].TargetGroupArn" --output text --region "$AWS_REGION" 2>/dev/null || echo "")
    [ -n "$TG_ARN" ] && [ "$TG_ARN" != "None" ] && \
      aws elbv2 delete-target-group --target-group-arn "$TG_ARN" --region "$AWS_REGION" 2>/dev/null || true
  done
done

echo "Deleting ECR repos..."
for REPO in app1-products app2-orders; do
  aws ecr delete-repository --repository-name "$REPO" --force --region "$AWS_REGION" 2>/dev/null || true
done

echo "Deleting SSM parameters..."
for P in /apps/app1/image_tag /apps/app1/image_tag_previous \
         /apps/app2/image_tag /apps/app2/image_tag_previous \
         /apps/releases/current /apps/releases/current_previous; do
  aws ssm delete-parameter --name "$P" --region "$AWS_REGION" 2>/dev/null || true
done

echo "Deleting IAM..."
aws iam remove-role-from-instance-profile --instance-profile-name "${PROJECT}-ec2-profile" \
  --role-name "${PROJECT}-ec2-role" 2>/dev/null || true
aws iam delete-instance-profile --instance-profile-name "${PROJECT}-ec2-profile" 2>/dev/null || true
aws iam delete-role-policy --role-name "${PROJECT}-ec2-role" --policy-name "${PROJECT}-ec2-policy" 2>/dev/null || true
aws iam delete-role --role-name "${PROJECT}-ec2-role" 2>/dev/null || true

echo "Deleting NAT Gateway..."
NAT_ID=$(aws ec2 describe-nat-gateways --filter "Name=tag:Name,Values=${PROJECT}-nat" \
  --query "NatGateways[0].NatGatewayId" --output text --region "$AWS_REGION" 2>/dev/null || echo "")
if [ -n "$NAT_ID" ] && [ "$NAT_ID" != "None" ]; then
  aws ec2 delete-nat-gateway --nat-gateway-id "$NAT_ID" --region "$AWS_REGION"
  echo "  Waiting for NAT deletion..."
  sleep 60
fi

echo "Releasing EIPs..."
EIPS=$(aws ec2 describe-addresses --filters "Name=domain,Values=vpc" \
  --query "Addresses[].AllocationId" --output text --region "$AWS_REGION" 2>/dev/null || echo "")
for EIP in $EIPS; do
  aws ec2 release-address --allocation-id "$EIP" --region "$AWS_REGION" 2>/dev/null || true
done

VPC_ID=$(aws ec2 describe-vpcs --filters "Name=tag:Name,Values=${PROJECT}-vpc" \
  --query "Vpcs[0].VpcId" --output text --region "$AWS_REGION" 2>/dev/null || echo "")

if [ -n "$VPC_ID" ] && [ "$VPC_ID" != "None" ]; then
  echo "Deleting VPC components..."
  # SGs
  for SG_NAME in "${PROJECT}-alb-sg" "${PROJECT}-ec2-sg"; do
    SG_ID=$(aws ec2 describe-security-groups --filters "Name=group-name,Values=$SG_NAME" "Name=vpc-id,Values=$VPC_ID" \
      --query "SecurityGroups[0].GroupId" --output text --region "$AWS_REGION" 2>/dev/null || echo "")
    [ -n "$SG_ID" ] && [ "$SG_ID" != "None" ] && \
      aws ec2 delete-security-group --group-id "$SG_ID" --region "$AWS_REGION" 2>/dev/null || true
  done

  # Subnets
  for SUB in $(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" \
    --query "Subnets[].SubnetId" --output text --region "$AWS_REGION" 2>/dev/null); do
    aws ec2 delete-subnet --subnet-id "$SUB" --region "$AWS_REGION" 2>/dev/null || true
  done

  # Route tables (non-main)
  for RT in $(aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$VPC_ID" \
    --query "RouteTables[?Associations[0].Main!=\`true\`].RouteTableId" --output text --region "$AWS_REGION" 2>/dev/null); do
    for ASSOC in $(aws ec2 describe-route-tables --route-table-ids "$RT" \
      --query "RouteTables[0].Associations[].RouteTableAssociationId" --output text --region "$AWS_REGION" 2>/dev/null); do
      aws ec2 disassociate-route-table --association-id "$ASSOC" --region "$AWS_REGION" 2>/dev/null || true
    done
    aws ec2 delete-route-table --route-table-id "$RT" --region "$AWS_REGION" 2>/dev/null || true
  done

  # IGW
  IGW=$(aws ec2 describe-internet-gateways --filters "Name=attachment.vpc-id,Values=$VPC_ID" \
    --query "InternetGateways[0].InternetGatewayId" --output text --region "$AWS_REGION" 2>/dev/null || echo "")
  if [ -n "$IGW" ] && [ "$IGW" != "None" ]; then
    aws ec2 detach-internet-gateway --internet-gateway-id "$IGW" --vpc-id "$VPC_ID" --region "$AWS_REGION"
    aws ec2 delete-internet-gateway --internet-gateway-id "$IGW" --region "$AWS_REGION"
  fi

  aws ec2 delete-vpc --vpc-id "$VPC_ID" --region "$AWS_REGION"
  echo "  VPC deleted: $VPC_ID"
fi

echo ""
echo "✅ Cleanup complete"
