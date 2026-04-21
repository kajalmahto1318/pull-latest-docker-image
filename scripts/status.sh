#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# Show deployment status: SSM tags, ASG health, active refreshes
# Usage: ./status.sh
# ─────────────────────────────────────────────────────────────────────────────
: "${AWS_REGION:=us-east-1}"
ASG_BLUE="bluegreen-asg-blue"
ASG_GREEN="bluegreen-asg-green"

echo "═══════════════════════════════════════════"
echo "  DEPLOYMENT STATUS  $(date -u)"
echo "═══════════════════════════════════════════"

echo ""
echo "  SSM Image Tags:"
for APP in app1 app2; do
  CUR=$(aws ssm get-parameter --name "/apps/${APP}/image_tag" \
    --query "Parameter.Value" --output text --region "$AWS_REGION" 2>/dev/null || echo "N/A")
  PREV=$(aws ssm get-parameter --name "/apps/${APP}/image_tag_previous" \
    --query "Parameter.Value" --output text --region "$AWS_REGION" 2>/dev/null || echo "N/A")
  echo "    $APP  current=$CUR  previous=$PREV"
done

echo ""
echo "  Release Manifest:"
MANIFEST=$(aws ssm get-parameter --name "/apps/releases/current" \
  --query "Parameter.Value" --output text --region "$AWS_REGION" 2>/dev/null || echo "N/A")
echo "    $MANIFEST"

echo ""
echo "  ASG Status:"
for ASG in "$ASG_BLUE" "$ASG_GREEN"; do
  INFO=$(aws autoscaling describe-auto-scaling-groups \
    --auto-scaling-group-names "$ASG" --region "$AWS_REGION" \
    --query "AutoScalingGroups[0].{D:DesiredCapacity,Min:MinSize,Max:MaxSize,Healthy:length(Instances[?HealthStatus=='Healthy'])}" \
    --output text 2>/dev/null || echo "N/A")
  echo "    $ASG: $INFO"
done

echo ""
echo "  Active Refreshes:"
for ASG in "$ASG_BLUE" "$ASG_GREEN"; do
  REFRESH=$(aws autoscaling describe-instance-refreshes \
    --auto-scaling-group-name "$ASG" --region "$AWS_REGION" \
    --query "InstanceRefreshes[?Status=='InProgress'].[InstanceRefreshId,Status,PercentageComplete]" \
    --output text 2>/dev/null || echo "none")
  echo "    $ASG: $REFRESH"
done
echo "═══════════════════════════════════════════"
