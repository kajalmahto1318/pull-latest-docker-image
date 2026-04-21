# Blue/Green Deployment — Docker + ECR + ASG + Packer

## Architecture

```
Developer Commit
   ↓
GitHub Actions (per repo)               concurrency: green-deployment
   ↓                                    (one deploy at a time, others QUEUE)
Build Docker Image
   ↓
Push → ECR (git-sha tag + latest)
   ↓
Update SSM (per-service tag + release manifest)
   ↓
Scale up GREEN ASG → trigger instance refresh
   ↓
EC2 boot → read SSM manifest → pull ALL images → run containers
   ↓
ALB health check passes
   ↓
switch-traffic.sh green  (ALB: BLUE → GREEN)
   ↓
Keep BLUE for instant rollback
```

## Project Structure

```
├── apps/
│   ├── app1-products/      ← Python Flask microservice (port 5001)
│   └── app2-orders/        ← Python Flask microservice (port 5002)
├── packer/
│   └── base-ami.pkr.hcl    ← Golden AMI: Docker + AWS CLI + jq + SSM
├── scripts/
│   ├── setup-infra.sh      ← One-time: create VPC, ALB, ASG, ECR, SSM (AWS CLI)
│   ├── user-data.sh        ← EC2 boot script (reads SSM → pulls images → runs)
│   ├── switch-traffic.sh   ← ALB traffic switch: blue ↔ green
│   ├── rollback.sh         ← Restore SSM + scale down GREEN
│   ├── status.sh           ← Show current deployment state
│   └── cleanup.sh          ← Delete all AWS resources
└── .github/workflows/
    ├── app1-deploy.yml      ← App1 CI/CD (test → build → deploy GREEN)
    ├── app2-deploy.yml      ← App2 CI/CD (test → build → deploy GREEN)
    └── rollback.yml         ← Manual rollback via GitHub UI
```

## Setup (Step by Step)

### 1. Build Base AMI with Packer

```bash
cd packer/
packer init .
packer build -var "region=us-east-1" base-ami.pkr.hcl
# Note the AMI ID from output: ami-xxxxxxxx
```

### 2. Create AWS Infrastructure

```bash
export AWS_REGION=us-east-1
export BASE_AMI_ID=ami-xxxxxxxx   # from step 1
bash scripts/setup-infra.sh
# Copy the output values for GitHub Secrets
```

### 3. Configure GitHub Secrets

From the setup output, add these secrets to your GitHub repo:

| Secret                | Value                      |
| --------------------- | -------------------------- |
| AWS_ACCESS_KEY_ID     | CI user access key         |
| AWS_SECRET_ACCESS_KEY | CI user secret key         |
| AWS_REGION            | us-east-1                  |
| AWS_ACCOUNT_ID        | 123456789012               |
| ASG_NAME_BLUE         | bluegreen-asg-blue         |
| ASG_NAME_GREEN        | bluegreen-asg-green        |
| ALB_LISTENER_ARN      | arn:aws:...listener/...    |
| TG_APP1_BLUE          | arn:aws:...targetgroup/... |
| TG_APP1_GREEN         | arn:aws:...targetgroup/... |
| TG_APP2_BLUE          | arn:aws:...targetgroup/... |
| TG_APP2_GREEN         | arn:aws:...targetgroup/... |

### 4. Push Code → Deploy

```bash
git push origin main
# GitHub Actions: test → build → push ECR → update SSM → deploy GREEN
```

### 5. Switch Traffic

After GREEN is healthy:

```bash
./scripts/switch-traffic.sh green
```

### 6. Rollback (if needed)

```bash
./scripts/rollback.sh
./scripts/switch-traffic.sh blue
```

Or use the GitHub Actions **Rollback to BLUE** workflow from the UI.

## Concurrent Deploy Safety

All app workflows share the same concurrency group:

```
App1 commits → [test] [build] [DEPLOY 🔒 locked]
App2 commits → [test] [build] [DEPLOY ⏳ queued — waiting for app1]
                                    ↓
                         App1 done → lock released
                                    ↓
                         App2 gets lock → reads updated manifest
                         → merges its tag → deploys to GREEN
                         → GREEN EC2s have BOTH new tags ✅
```

- Build runs in parallel (no blocking)
- Only deploy is serialized (one at a time)
- Queue visible in GitHub Actions UI (yellow "waiting" status)
- No race conditions, no mixed versions

## How Autoscaling Always Gets Latest Tags

1. Launch Template has NO image tag hardcoded
2. User-data script reads SSM release manifest at boot time
3. Any new EC2 (scale-out) automatically gets the latest approved tags
4. No stale versions ever

## Cleanup

```bash
bash scripts/cleanup.sh
```

# Production-Grade Auto Scaling with Dynamic Docker Image Tags

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────┐
│                        FULL FLOW                                     │
├─────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  Developer Push → GitHub Actions                                     │
│       │                                                              │
│       ├─► Build Docker Image                                         │
│       ├─► Tag: git-SHA + latest                                      │
│       ├─► Push → AWS ECR                                             │
│       ├─► Update SSM Parameter Store  (/app/<name>/image_tag)        │
│       └─► Trigger ASG Instance Refresh (Rolling / Blue-Green)        │
│                                                                      │
│  Auto Scaling Group                                                  │
│       │                                                              │
│       ├─► Launch Template (base AMI with Docker installed)           │
│       ├─► User Data script runs at boot:                             │
│       │     1. Read image_tag from SSM Parameter Store               │
│       │     2. aws ecr get-login-password | docker login             │
│       │     3. docker pull <ECR_URI>:<image_tag>                     │
│       │     4. docker run -d --env-file /etc/app/.env ...            │
│       │                                                              │
│       └─► ALB Health Check → traffic shifts → old EC2 terminated    │
│                                                                      │
│  Rollback:                                                           │
│       └─► Update SSM param → old_tag → Trigger Instance Refresh     │
│                                                                      │
└─────────────────────────────────────────────────────────────────────┘
```

## Why NOT Packer for this use case?

| Approach       | Packer AMI Baking       | ✅ Our Approach (Dynamic User Data) |
| -------------- | ----------------------- | ----------------------------------- |
| Image tag      | Baked into AMI (static) | Read from SSM at boot (dynamic)     |
| New deployment | Need new AMI per deploy | Just update SSM + trigger refresh   |
| Rollback       | Need old AMI ID         | Update SSM to old tag               |
| Boot time      | Faster (pre-baked)      | ~30s extra for docker pull          |
| Flexibility    | Low                     | High                                |

> **Packer IS useful** for pre-installing Docker, CloudWatch agent, etc. on the base AMI.
> We use Packer ONCE to create a base AMI with Docker installed, then User Data handles the app.

## Repositories Structure (Demo)

```
pull-latest-docker-image/
├── apps/
│   ├── app1-nodejs/          ← Repo 1: Node.js Express API
│   └── app2-python/          ← Repo 2: Python FastAPI
├── .github/workflows/
│   ├── app1-ci-cd.yml        ← GitHub Actions for App1
│   └── app2-ci-cd.yml        ← GitHub Actions for App2
├── infrastructure/
│   └── terraform/            ← All AWS infrastructure as code
├── packer/
│   └── base-ami.pkr.hcl      ← Packer: base AMI with Docker
└── scripts/
    ├── user-data.sh          ← EC2 boot script
    └── rollback.sh           ← Manual rollback script
```

## Prerequisites

- AWS Account with appropriate permissions
- Terraform >= 1.5
- Packer >= 1.9
- GitHub repository secrets configured (see below)

## GitHub Secrets Required

```
AWS_ACCESS_KEY_ID
AWS_SECRET_ACCESS_KEY
AWS_REGION          (e.g., us-east-1)
AWS_ACCOUNT_ID      (12-digit AWS account ID)
ASG_NAME_BLUE       (from terraform output)
ASG_NAME_GREEN      (from terraform output)
SSM_RELEASE_PARAM   (from terraform output)
```

## Deployment Steps

### Step 1: Build Base AMI with Packer

```bash
cd packer/
packer init .
packer build -var "region=us-east-1" base-ami.pkr.hcl
# Note the AMI ID from output
```

### Step 2: Deploy Infrastructure with Terraform

```bash
cd infrastructure/terraform/
terraform init
terraform plan -var="base_ami_id=ami-XXXXXXXX"
terraform apply -var="base_ami_id=ami-XXXXXXXX"
```

### Step 3: Push Code to Trigger CI/CD

```bash
# Any push to main branch triggers GitHub Actions
git push origin main
# → Builds image → Pushes to ECR → Updates SSM release manifest → Triggers GREEN refresh
```

### Step 4: Rollback (if needed)

```bash
./scripts/rollback.sh app1 git-abc1234
# → Updates SSM to old tag → Triggers Instance Refresh → gradual replacement
```

## Blue/Green Deployment Flow

```
Before Deploy:
  ALB → Target Group BLUE (v1 running) ✅

Deploy Triggered:
  GREEN ASG Instance Refresh starts
  New GREEN EC2s launch (pull approved release from SSM)
  ALB health check passes on new EC2s ✅
  ALB traffic shifts from BLUE target groups to GREEN target groups
  BLUE EC2s stay available for rollback window

Result:
  ALB → Target Group (v2 running) ✅ Zero downtime
```
