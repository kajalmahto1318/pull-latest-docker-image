#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# EC2 User Data — Runs at every new instance boot
#
# 1. Read release manifest from SSM (all service tags in one JSON)
# 2. Fallback to per-service SSM tags if manifest unavailable
# 3. Login to ECR
# 4. Pull ALL microservice images
# 5. Run containers
# 6. Health check
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail
exec > >(tee /var/log/user-data.log | logger -t user-data -s 2>/dev/console) 2>&1

echo "══════════════════════════════════════════"
echo "  EC2 Boot: $(date)"
echo "══════════════════════════════════════════"

# ─── Config (set by launch template tags / env) ──────────────────────────────
AWS_REGION="${AWS_REGION:-us-east-1}"
RELEASE_PARAM="${RELEASE_PARAM:-/apps/releases/current}"
SSM_APP1="${SSM_APP1:-/apps/app1/image_tag}"
SSM_APP2="${SSM_APP2:-/apps/app2/image_tag}"
ECR_REPO_APP1="${ECR_REPO_APP1:-app1-products}"
ECR_REPO_APP2="${ECR_REPO_APP2:-app2-orders}"
PORT_APP1="${PORT_APP1:-5001}"
PORT_APP2="${PORT_APP2:-5002}"

# Detect account ID from instance metadata
TOKEN=$(curl -s -X PUT http://169.254.169.254/latest/api/token -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
INSTANCE_ID=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-id)
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text --region "$AWS_REGION")
ECR_REGISTRY="${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"

echo "  Instance: $INSTANCE_ID"
echo "  Account:  $ACCOUNT_ID"
echo "  Region:   $AWS_REGION"

# ─── Start Docker ─────────────────────────────────────────────────────────────
systemctl start docker || true

# ─── SSM read helper ──────────────────────────────────────────────────────────
get_ssm() {
  local name="$1" retries=5 delay=3
  for i in $(seq 1 $retries); do
    VAL=$(aws ssm get-parameter --name "$name" --query "Parameter.Value" \
      --output text --region "$AWS_REGION" 2>/dev/null || echo "")
    if [ -n "$VAL" ] && [ "$VAL" != "None" ]; then
      echo "$VAL"
      return 0
    fi
    echo "  SSM retry $i for $name..." >&2
    sleep $delay
  done
  return 1
}

# ─── Read image tags ──────────────────────────────────────────────────────────
echo "Reading release manifest from SSM..."

MANIFEST=$(get_ssm "$RELEASE_PARAM" || echo "")
if [ -n "$MANIFEST" ]; then
  TAG_APP1=$(echo "$MANIFEST" | jq -r '.services.app1 // empty')
  TAG_APP2=$(echo "$MANIFEST" | jq -r '.services.app2 // empty')
fi

# Fallback to per-service params
if [ -z "${TAG_APP1:-}" ]; then TAG_APP1=$(get_ssm "$SSM_APP1"); fi
if [ -z "${TAG_APP2:-}" ]; then TAG_APP2=$(get_ssm "$SSM_APP2"); fi

echo "  app1 tag: $TAG_APP1"
echo "  app2 tag: $TAG_APP2"

# ─── ECR login ────────────────────────────────────────────────────────────────
echo "Logging into ECR..."
aws ecr get-login-password --region "$AWS_REGION" | \
  docker login --username AWS --password-stdin "$ECR_REGISTRY"

# ─── Pull images (with retry) ─────────────────────────────────────────────────
pull() {
  local img="$1" retries=3
  for i in $(seq 1 $retries); do
    docker pull "$img" && return 0
    echo "  Pull retry $i for $img..." >&2
    sleep 5
  done
  return 1
}

IMG_APP1="$ECR_REGISTRY/$ECR_REPO_APP1:$TAG_APP1"
IMG_APP2="$ECR_REGISTRY/$ECR_REPO_APP2:$TAG_APP2"

pull "$IMG_APP1"
pull "$IMG_APP2"

# ─── Stop old containers ──────────────────────────────────────────────────────
docker stop app1 app2 2>/dev/null || true
docker rm   app1 app2 2>/dev/null || true

# ─── Run containers ───────────────────────────────────────────────────────────
echo "Starting containers..."

docker run -d \
  --name app1 \
  --restart unless-stopped \
  -p "$PORT_APP1:$PORT_APP1" \
  -e PORT="$PORT_APP1" \
  -e APP_VERSION="$TAG_APP1" \
  -e ENVIRONMENT="production" \
  --memory=256m --cpus=0.5 \
  "$IMG_APP1"

docker run -d \
  --name app2 \
  --restart unless-stopped \
  -p "$PORT_APP2:$PORT_APP2" \
  -e PORT="$PORT_APP2" \
  -e APP_VERSION="$TAG_APP2" \
  -e ENVIRONMENT="production" \
  --memory=256m --cpus=0.5 \
  "$IMG_APP2"

# ─── Health check ─────────────────────────────────────────────────────────────
echo "Waiting for health checks..."
for port in $PORT_APP1 $PORT_APP2; do
  for i in $(seq 1 12); do
    if curl -sf "http://localhost:$port/health" > /dev/null 2>&1; then
      echo "  Port $port healthy"
      break
    fi
    [ "$i" -eq 12 ] && echo "  Port $port FAILED health check!"
    sleep 5
  done
done

docker image prune -f

echo "══════════════════════════════════════════"
echo "  Boot complete: $(date)"
echo "  app1=$TAG_APP1  app2=$TAG_APP2"
echo "══════════════════════════════════════════"
