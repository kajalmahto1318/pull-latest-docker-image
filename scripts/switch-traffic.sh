#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# Switch ALB traffic: BLUE ↔ GREEN
#
# Usage:
#   ./switch-traffic.sh green   # Switch traffic to GREEN
#   ./switch-traffic.sh blue    # Switch traffic back to BLUE (rollback)
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

: "${AWS_REGION:=us-east-1}"

TARGET="${1:?Usage: $0 <blue|green>}"
[[ "$TARGET" != "blue" && "$TARGET" != "green" ]] && echo "Must be blue or green" && exit 1

# These must be set as environment variables or edited here
: "${ALB_LISTENER_ARN:?Set ALB_LISTENER_ARN}"
: "${TG_APP1_BLUE:?Set TG_APP1_BLUE}"
: "${TG_APP1_GREEN:?Set TG_APP1_GREEN}"
: "${TG_APP2_BLUE:?Set TG_APP2_BLUE}"
: "${TG_APP2_GREEN:?Set TG_APP2_GREEN}"

if [ "$TARGET" = "green" ]; then
  TG_APP1="$TG_APP1_GREEN"
  TG_APP2="$TG_APP2_GREEN"
else
  TG_APP1="$TG_APP1_BLUE"
  TG_APP2="$TG_APP2_BLUE"
fi

echo "Switching traffic to $TARGET..."

# Default action → app1
aws elbv2 modify-listener --listener-arn "$ALB_LISTENER_ARN" \
  --default-actions "Type=forward,TargetGroupArn=$TG_APP1" --region "$AWS_REGION" > /dev/null

# Rule for /orders* → app2
RULE_ARN=$(aws elbv2 describe-rules --listener-arn "$ALB_LISTENER_ARN" \
  --query "Rules[?Priority=='100'].RuleArn" --output text --region "$AWS_REGION")
if [ -n "$RULE_ARN" ]; then
  aws elbv2 modify-rule --rule-arn "$RULE_ARN" \
    --actions "Type=forward,TargetGroupArn=$TG_APP2" --region "$AWS_REGION" > /dev/null
fi

echo "✅ Traffic now on $TARGET"
echo "   app1 → $TG_APP1"
echo "   app2 → $TG_APP2"
