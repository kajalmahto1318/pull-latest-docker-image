#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# Emergency Rollback — ALB → BLUE + SSM restore + GREEN down
#
# This is for emergency ONLY (if GitHub Actions is down).
# Normal rollback = GitHub Actions "Rollback to BLUE" workflow (1 click).
#
# Usage: ./rollback.sh
# Required env: ALB_LISTENER_ARN, TG_APP1_BLUE, TG_APP2_BLUE
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

: "${AWS_REGION:=us-east-1}"
: "${ALB_LISTENER_ARN:?Set ALB_LISTENER_ARN}"
: "${TG_APP1_BLUE:?Set TG_APP1_BLUE}"
: "${TG_APP2_BLUE:?Set TG_APP2_BLUE}"

ASG_BLUE="bluegreen-asg-blue"
ASG_GREEN="bluegreen-asg-green"

echo "═══ EMERGENCY ROLLBACK TO BLUE ═══"

echo "Switching ALB → BLUE..."
aws elbv2 modify-listener --listener-arn "$ALB_LISTENER_ARN" \
  --default-actions "Type=forward,TargetGroupArn=$TG_APP1_BLUE" --region "$AWS_REGION" > /dev/null

RULE_ARN=$(aws elbv2 describe-rules --listener-arn "$ALB_LISTENER_ARN" \
  --query "Rules[?Priority=='100'].RuleArn" --output text --region "$AWS_REGION")
if [ -n "$RULE_ARN" ] && [ "$RULE_ARN" != "None" ]; then
  aws elbv2 modify-rule --rule-arn "$RULE_ARN" \
    --actions "Type=forward,TargetGroupArn=$TG_APP2_BLUE" --region "$AWS_REGION" > /dev/null
fi
echo "  ✅ Traffic on BLUE"

echo "Scaling up BLUE..."
aws autoscaling update-auto-scaling-group \
  --auto-scaling-group-name "$ASG_BLUE" \
  --min-size 1 --desired-capacity 2 --max-size 4 --region "$AWS_REGION"
echo "  ✅ BLUE scaled to 2"

echo "Restoring SSM..."
for APP in app1 app2; do
  PREV=$(aws ssm get-parameter --name "/apps/${APP}/image_tag_previous" \
    --query "Parameter.Value" --output text --region "$AWS_REGION" 2>/dev/null || echo "")
  if [ -n "$PREV" ] && [ "$PREV" != "None" ]; then
    aws ssm put-parameter --name "/apps/${APP}/image_tag" \
      --value "$PREV" --type String --overwrite --region "$AWS_REGION" > /dev/null
    echo "  ✅ /apps/${APP}/image_tag → $PREV"
  fi
done

PREV_MANIFEST=$(aws ssm get-parameter --name "/apps/releases/current_previous" \
  --query "Parameter.Value" --output text --region "$AWS_REGION" 2>/dev/null || echo "")
if [ -n "$PREV_MANIFEST" ] && [ "$PREV_MANIFEST" != "None" ]; then
  aws ssm put-parameter --name "/apps/releases/current" \
    --value "$PREV_MANIFEST" --type String --overwrite --region "$AWS_REGION" > /dev/null
  echo "  ✅ Manifest restored"
fi

echo "Scaling down GREEN..."
aws autoscaling cancel-instance-refresh \
  --auto-scaling-group-name "$ASG_GREEN" --region "$AWS_REGION" 2>/dev/null || true
aws autoscaling update-auto-scaling-group \
  --auto-scaling-group-name "$ASG_GREEN" \
  --min-size 0 --desired-capacity 0 --region "$AWS_REGION"
echo "  ✅ GREEN scaled to 0"

echo "Refreshing BLUE..."
aws autoscaling cancel-instance-refresh \
  --auto-scaling-group-name "$ASG_BLUE" --region "$AWS_REGION" 2>/dev/null || true
sleep 5
aws autoscaling start-instance-refresh \
  --auto-scaling-group-name "$ASG_BLUE" \
  --strategy Rolling \
  --preferences '{"MinHealthyPercentage":50,"InstanceWarmup":120}' \
  --region "$AWS_REGION" || true

echo ""
echo "═══════════════════════════════════════"
echo "  ✅ ROLLBACK COMPLETE"
echo "  Traffic: BLUE (live)"
echo "  GREEN:   scaled to 0"
echo "  SSM:     restored to previous"
echo "═══════════════════════════════════════"
