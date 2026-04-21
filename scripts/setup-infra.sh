#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# One-time AWS infrastructure setup using AWS CLI (no Terraform)
#
# Creates: VPC, Subnets, ALB, Target Groups (blue/green per app),
#          2 ASGs (blue/green), ECR repos, SSM params, IAM roles, SGs
#
# Usage:
#   export AWS_REGION=us-east-1
#   bash scripts/setup-infra.sh
#
# AMI ID is auto-detected from Packer output (latest bluegreen-base-* AMI)
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

: "${AWS_REGION:=us-east-1}"
PROJECT="bluegreen"

# ─── Auto-fetch latest Golden AMI ────────────────────────────────────────────
if [ -z "${BASE_AMI_ID:-}" ]; then
  echo "🔍 Auto-detecting latest Golden AMI (bluegreen-base-*)..."

  # Method 1: Try packer-manifest.json (if run from repo root)
  if [ -f "packer/packer-manifest.json" ]; then
    BASE_AMI_ID=$(jq -r '.builds[-1].artifact_id' packer/packer-manifest.json | cut -d: -f2)
    echo "  Found in packer-manifest.json: $BASE_AMI_ID"
  fi

  # Method 2: Query AWS for latest AMI by name
  if [ -z "${BASE_AMI_ID:-}" ] || [ "$BASE_AMI_ID" = "null" ]; then
    ACCOUNT_ID_TMP=$(aws sts get-caller-identity --query Account --output text)
    BASE_AMI_ID=$(aws ec2 describe-images \
      --owners "$ACCOUNT_ID_TMP" \
      --filters "Name=name,Values=bluegreen-base-*" "Name=state,Values=available" \
      --query "sort_by(Images, &CreationDate)[-1].ImageId" \
      --output text --region "$AWS_REGION")
    echo "  Found in AWS (latest): $BASE_AMI_ID"
  fi

  if [ -z "${BASE_AMI_ID:-}" ] || [ "$BASE_AMI_ID" = "None" ] || [ "$BASE_AMI_ID" = "null" ]; then
    echo "❌ No Golden AMI found! Run Packer first:"
    echo "   cd packer && packer build -var region=$AWS_REGION base-ami.pkr.hcl"
    exit 1
  fi
fi

echo "✅ Using AMI: $BASE_AMI_ID"
INSTANCE_TYPE="t3.micro"
VPC_CIDR="10.0.0.0/16"
PUB1_CIDR="10.0.1.0/24"
PUB2_CIDR="10.0.2.0/24"
PRIV1_CIDR="10.0.11.0/24"
PRIV2_CIDR="10.0.12.0/24"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

echo "Account: $ACCOUNT_ID | Region: $AWS_REGION | AMI: $BASE_AMI_ID"

# ─── Get AZs ──────────────────────────────────────────────────────────────────
AZ1=$(aws ec2 describe-availability-zones --region "$AWS_REGION" \
  --query "AvailabilityZones[0].ZoneName" --output text)
AZ2=$(aws ec2 describe-availability-zones --region "$AWS_REGION" \
  --query "AvailabilityZones[1].ZoneName" --output text)
echo "AZs: $AZ1, $AZ2"

# ═══ VPC ═══════════════════════════════════════════════════════════════════════
echo "Creating VPC..."
VPC_ID=$(aws ec2 create-vpc --cidr-block "$VPC_CIDR" \
  --tag-specifications "ResourceType=vpc,Tags=[{Key=Name,Value=${PROJECT}-vpc}]" \
  --query "Vpc.VpcId" --output text --region "$AWS_REGION")
aws ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-hostnames --region "$AWS_REGION"
echo "  VPC: $VPC_ID"

# ─── Internet Gateway ─────────────────────────────────────────────────────────
IGW_ID=$(aws ec2 create-internet-gateway \
  --tag-specifications "ResourceType=internet-gateway,Tags=[{Key=Name,Value=${PROJECT}-igw}]" \
  --query "InternetGateway.InternetGatewayId" --output text --region "$AWS_REGION")
aws ec2 attach-internet-gateway --internet-gateway-id "$IGW_ID" --vpc-id "$VPC_ID" --region "$AWS_REGION"

# ─── Public Subnets ───────────────────────────────────────────────────────────
PUB1=$(aws ec2 create-subnet --vpc-id "$VPC_ID" --cidr-block "$PUB1_CIDR" \
  --availability-zone "$AZ1" \
  --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=${PROJECT}-pub-1}]" \
  --query "Subnet.SubnetId" --output text --region "$AWS_REGION")
aws ec2 modify-subnet-attribute --subnet-id "$PUB1" --map-public-ip-on-launch --region "$AWS_REGION"

PUB2=$(aws ec2 create-subnet --vpc-id "$VPC_ID" --cidr-block "$PUB2_CIDR" \
  --availability-zone "$AZ2" \
  --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=${PROJECT}-pub-2}]" \
  --query "Subnet.SubnetId" --output text --region "$AWS_REGION")
aws ec2 modify-subnet-attribute --subnet-id "$PUB2" --map-public-ip-on-launch --region "$AWS_REGION"

# ─── Private Subnets ──────────────────────────────────────────────────────────
PRIV1=$(aws ec2 create-subnet --vpc-id "$VPC_ID" --cidr-block "$PRIV1_CIDR" \
  --availability-zone "$AZ1" \
  --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=${PROJECT}-priv-1}]" \
  --query "Subnet.SubnetId" --output text --region "$AWS_REGION")
PRIV2=$(aws ec2 create-subnet --vpc-id "$VPC_ID" --cidr-block "$PRIV2_CIDR" \
  --availability-zone "$AZ2" \
  --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=${PROJECT}-priv-2}]" \
  --query "Subnet.SubnetId" --output text --region "$AWS_REGION")

# ─── Public Route Table ───────────────────────────────────────────────────────
PUB_RT=$(aws ec2 create-route-table --vpc-id "$VPC_ID" \
  --tag-specifications "ResourceType=route-table,Tags=[{Key=Name,Value=${PROJECT}-pub-rt}]" \
  --query "RouteTable.RouteTableId" --output text --region "$AWS_REGION")
aws ec2 create-route --route-table-id "$PUB_RT" --destination-cidr-block "0.0.0.0/0" \
  --gateway-id "$IGW_ID" --region "$AWS_REGION" > /dev/null
aws ec2 associate-route-table --route-table-id "$PUB_RT" --subnet-id "$PUB1" --region "$AWS_REGION" > /dev/null
aws ec2 associate-route-table --route-table-id "$PUB_RT" --subnet-id "$PUB2" --region "$AWS_REGION" > /dev/null

# ─── NAT Gateway ──────────────────────────────────────────────────────────────
echo "Creating NAT Gateway (takes ~2 min)..."
EIP_ALLOC=$(aws ec2 allocate-address --domain vpc --query "AllocationId" --output text --region "$AWS_REGION")
NAT_ID=$(aws ec2 create-nat-gateway --subnet-id "$PUB1" --allocation-id "$EIP_ALLOC" \
  --tag-specifications "ResourceType=natgateway,Tags=[{Key=Name,Value=${PROJECT}-nat}]" \
  --query "NatGateway.NatGatewayId" --output text --region "$AWS_REGION")
aws ec2 wait nat-gateway-available --nat-gateway-ids "$NAT_ID" --region "$AWS_REGION"
echo "  NAT: $NAT_ID"

# ─── Private Route Table ──────────────────────────────────────────────────────
PRIV_RT=$(aws ec2 create-route-table --vpc-id "$VPC_ID" \
  --tag-specifications "ResourceType=route-table,Tags=[{Key=Name,Value=${PROJECT}-priv-rt}]" \
  --query "RouteTable.RouteTableId" --output text --region "$AWS_REGION")
aws ec2 create-route --route-table-id "$PRIV_RT" --destination-cidr-block "0.0.0.0/0" \
  --nat-gateway-id "$NAT_ID" --region "$AWS_REGION" > /dev/null
aws ec2 associate-route-table --route-table-id "$PRIV_RT" --subnet-id "$PRIV1" --region "$AWS_REGION" > /dev/null
aws ec2 associate-route-table --route-table-id "$PRIV_RT" --subnet-id "$PRIV2" --region "$AWS_REGION" > /dev/null

# ═══ Security Groups ══════════════════════════════════════════════════════════
echo "Creating Security Groups..."
ALB_SG=$(aws ec2 create-security-group --group-name "${PROJECT}-alb-sg" \
  --description "ALB SG" --vpc-id "$VPC_ID" \
  --query "GroupId" --output text --region "$AWS_REGION")
aws ec2 authorize-security-group-ingress --group-id "$ALB_SG" --protocol tcp \
  --port 80 --cidr "0.0.0.0/0" --region "$AWS_REGION" > /dev/null

EC2_SG=$(aws ec2 create-security-group --group-name "${PROJECT}-ec2-sg" \
  --description "EC2 SG - only ALB" --vpc-id "$VPC_ID" \
  --query "GroupId" --output text --region "$AWS_REGION")
aws ec2 authorize-security-group-ingress --group-id "$EC2_SG" --protocol tcp \
  --port 5001 --source-group "$ALB_SG" --region "$AWS_REGION" > /dev/null
aws ec2 authorize-security-group-ingress --group-id "$EC2_SG" --protocol tcp \
  --port 5002 --source-group "$ALB_SG" --region "$AWS_REGION" > /dev/null
# Outbound already open by default

# ═══ ECR ═══════════════════════════════════════════════════════════════════════
echo "Creating ECR repos..."
for REPO in app1-products app2-orders; do
  aws ecr create-repository --repository-name "$REPO" \
    --image-scanning-configuration scanOnPush=true \
    --region "$AWS_REGION" 2>/dev/null || echo "  $REPO already exists"
done

# ═══ SSM Parameters ═══════════════════════════════════════════════════════════
echo "Creating SSM parameters..."
aws ssm put-parameter --name "/apps/app1/image_tag" --value "latest" --type String --overwrite --region "$AWS_REGION" > /dev/null
aws ssm put-parameter --name "/apps/app2/image_tag" --value "latest" --type String --overwrite --region "$AWS_REGION" > /dev/null
aws ssm put-parameter --name "/apps/app1/image_tag_previous" --value "latest" --type String --overwrite --region "$AWS_REGION" > /dev/null
aws ssm put-parameter --name "/apps/app2/image_tag_previous" --value "latest" --type String --overwrite --region "$AWS_REGION" > /dev/null

INIT_MANIFEST='{"release_id":"initial","services":{"app1":"latest","app2":"latest"}}'
aws ssm put-parameter --name "/apps/releases/current" --value "$INIT_MANIFEST" --type String --overwrite --region "$AWS_REGION" > /dev/null
aws ssm put-parameter --name "/apps/releases/current_previous" --value "$INIT_MANIFEST" --type String --overwrite --region "$AWS_REGION" > /dev/null

# ═══ IAM Role for EC2 ═════════════════════════════════════════════════════════
echo "Creating IAM role..."
TRUST_POLICY='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}'

aws iam create-role --role-name "${PROJECT}-ec2-role" \
  --assume-role-policy-document "$TRUST_POLICY" 2>/dev/null || true

# EC2 needs: ECR pull + SSM read + STS (for account ID)
cat > /tmp/ec2-policy.json << 'POLICY'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["ecr:GetAuthorizationToken"],
      "Resource": "*"
    },
    {
      "Effect": "Allow",
      "Action": [
        "ecr:GetDownloadUrlForLayer",
        "ecr:BatchGetImage",
        "ecr:BatchCheckLayerAvailability"
      ],
      "Resource": "arn:aws:ecr:*:*:repository/app*"
    },
    {
      "Effect": "Allow",
      "Action": [
        "ssm:GetParameter",
        "ssm:GetParameters",
        "ssm:GetParametersByPath"
      ],
      "Resource": "arn:aws:ssm:*:*:parameter/apps/*"
    },
    {
      "Effect": "Allow",
      "Action": ["sts:GetCallerIdentity"],
      "Resource": "*"
    }
  ]
}
POLICY

aws iam put-role-policy --role-name "${PROJECT}-ec2-role" \
  --policy-name "${PROJECT}-ec2-policy" \
  --policy-document file:///tmp/ec2-policy.json

aws iam create-instance-profile --instance-profile-name "${PROJECT}-ec2-profile" 2>/dev/null || true
aws iam add-role-to-instance-profile --instance-profile-name "${PROJECT}-ec2-profile" \
  --role-name "${PROJECT}-ec2-role" 2>/dev/null || true

echo "  Waiting 10s for IAM propagation..."
sleep 10

# ═══ ALB ═══════════════════════════════════════════════════════════════════════
echo "Creating ALB..."
ALB_ARN=$(aws elbv2 create-load-balancer --name "${PROJECT}-alb" \
  --subnets "$PUB1" "$PUB2" --security-groups "$ALB_SG" --scheme internet-facing \
  --type application --query "LoadBalancers[0].LoadBalancerArn" --output text --region "$AWS_REGION")
echo "  ALB: $ALB_ARN"

# ─── Target Groups (4 total: app1-blue, app1-green, app2-blue, app2-green) ───
echo "Creating Target Groups..."
for COLOR in blue green; do
  for APP_PORT in "app1:5001" "app2:5002"; do
    APP="${APP_PORT%%:*}"
    PORT="${APP_PORT##*:}"
    TG_ARN=$(aws elbv2 create-target-group --name "${PROJECT}-${APP}-${COLOR}" \
      --protocol HTTP --port "$PORT" --vpc-id "$VPC_ID" --target-type instance \
      --health-check-path "/health" --health-check-interval-seconds 15 \
      --healthy-threshold-count 2 --unhealthy-threshold-count 3 \
      --query "TargetGroups[0].TargetGroupArn" --output text --region "$AWS_REGION")
    echo "  TG: ${APP}-${COLOR} = $TG_ARN"
    # Store for later use
    eval "TG_${APP}_${COLOR}=$TG_ARN"
  done
done

# ─── Listener (port 80) → default to app1-blue ───────────────────────────────
LISTENER_ARN=$(aws elbv2 create-listener --load-balancer-arn "$ALB_ARN" \
  --protocol HTTP --port 80 \
  --default-actions "Type=forward,TargetGroupArn=$TG_app1_blue" \
  --query "Listeners[0].ListenerArn" --output text --region "$AWS_REGION")

# Rule: /orders* → app2-blue
aws elbv2 create-rule --listener-arn "$LISTENER_ARN" --priority 100 \
  --conditions "Field=path-pattern,Values=/orders*,/health-app2*" \
  --actions "Type=forward,TargetGroupArn=$TG_app2_blue" \
  --region "$AWS_REGION" > /dev/null

echo "  Listener: $LISTENER_ARN (BLUE active)"

# ═══ Launch Template ══════════════════════════════════════════════════════════
echo "Creating Launch Template..."

# Encode user-data
USER_DATA_B64=$(base64 -w0 scripts/user-data.sh)

LT_ID=$(aws ec2 create-launch-template --launch-template-name "${PROJECT}-lt" \
  --launch-template-data "{
    \"ImageId\": \"$BASE_AMI_ID\",
    \"InstanceType\": \"$INSTANCE_TYPE\",
    \"IamInstanceProfile\": {\"Name\": \"${PROJECT}-ec2-profile\"},
    \"NetworkInterfaces\": [{
      \"DeviceIndex\": 0,
      \"AssociatePublicIpAddress\": false,
      \"Groups\": [\"$EC2_SG\"]
    }],
    \"MetadataOptions\": {
      \"HttpTokens\": \"required\",
      \"HttpEndpoint\": \"enabled\",
      \"HttpPutResponseHopLimit\": 2
    },
    \"UserData\": \"$USER_DATA_B64\",
    \"TagSpecifications\": [{
      \"ResourceType\": \"instance\",
      \"Tags\": [{\"Key\": \"Name\", \"Value\": \"${PROJECT}-ec2\"}]
    }]
  }" --query "LaunchTemplate.LaunchTemplateId" --output text --region "$AWS_REGION")
echo "  LT: $LT_ID"

# ═══ Auto Scaling Groups (Blue + Green) ═══════════════════════════════════════
echo "Creating ASGs..."

for COLOR in blue green; do
  if [ "$COLOR" = "blue" ]; then
    MIN=1; DESIRED=2; MAX=4
    TG1="$TG_app1_blue"; TG2="$TG_app2_blue"
  else
    MIN=0; DESIRED=0; MAX=4
    TG1="$TG_app1_green"; TG2="$TG_app2_green"
  fi

  aws autoscaling create-auto-scaling-group \
    --auto-scaling-group-name "${PROJECT}-asg-${COLOR}" \
    --launch-template "LaunchTemplateId=$LT_ID,Version=\$Latest" \
    --min-size "$MIN" --max-size "$MAX" --desired-capacity "$DESIRED" \
    --vpc-zone-identifier "${PRIV1},${PRIV2}" \
    --target-group-arns "$TG1" "$TG2" \
    --health-check-type ELB --health-check-grace-period 120 \
    --tags "Key=Name,Value=${PROJECT}-ec2-${COLOR},PropagateAtLaunch=true" \
           "Key=Color,Value=${COLOR},PropagateAtLaunch=true" \
    --region "$AWS_REGION"

  echo "  ASG: ${PROJECT}-asg-${COLOR} (desired=$DESIRED)"
done

# ═══ Output ════════════════════════════════════════════════════════════════════
ALB_DNS=$(aws elbv2 describe-load-balancers --load-balancer-arns "$ALB_ARN" \
  --query "LoadBalancers[0].DNSName" --output text --region "$AWS_REGION")

echo ""
echo "═══════════════════════════════════════════════════════════"
echo "  SETUP COMPLETE"
echo "═══════════════════════════════════════════════════════════"
echo ""
echo "  ALB URL:          http://$ALB_DNS"
echo "  ASG Blue:         ${PROJECT}-asg-blue   (ACTIVE — serving traffic)"
echo "  ASG Green:        ${PROJECT}-asg-green  (STANDBY — desired=0)"
echo "  ECR:              $ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com"
echo "  Launch Template:  $LT_ID"
echo ""
echo "  GitHub Secrets to set:"
echo "  ──────────────────────"
echo "  AWS_REGION         = $AWS_REGION"
echo "  AWS_ACCOUNT_ID     = $ACCOUNT_ID"
echo "  ASG_NAME_BLUE      = ${PROJECT}-asg-blue"
echo "  ASG_NAME_GREEN     = ${PROJECT}-asg-green"
echo "  ALB_LISTENER_ARN   = $LISTENER_ARN"
echo "  TG_APP1_BLUE       = $TG_app1_blue"
echo "  TG_APP1_GREEN      = $TG_app1_green"
echo "  TG_APP2_BLUE       = $TG_app2_blue"
echo "  TG_APP2_GREEN      = $TG_app2_green"
echo ""
echo "  (Also set AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY"
echo "   for a CI user with: ECR push, SSM write, ASG refresh,"
echo "   ELB ModifyListener/ModifyRule/DescribeRules permissions)"
echo "═══════════════════════════════════════════════════════════"
