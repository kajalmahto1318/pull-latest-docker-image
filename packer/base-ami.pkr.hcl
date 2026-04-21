# ─────────────────────────────────────────────────────────────────────────────
# Packer — Golden Base AMI
#
# Pre-installs Docker, AWS CLI, SSM Agent, jq so EC2 boots in ~20-30s
# App containers are NOT baked — pulled dynamically from ECR at boot via SSM tags
#
# Build:
#   packer init .
#   packer build -var "region=us-east-1" base-ami.pkr.hcl
# ─────────────────────────────────────────────────────────────────────────────

packer {
  required_plugins {
    amazon = {
      version = ">= 1.3.0"
      source  = "github.com/hashicorp/amazon"
    }
  }
}

variable "region" {
  type    = string
  default = "us-east-1"
}

variable "instance_type" {
  type    = string
  default = "t3.micro"
}

variable "ami_name_prefix" {
  type    = string
  default = "bluegreen-base"
}

variable "subnet_id" {
  type        = string
  description = "Subnet ID to launch the Packer builder instance in"
}

source "amazon-ebs" "base" {
  region        = var.region
  instance_type = var.instance_type
  ami_name      = "${var.ami_name_prefix}-${formatdate("YYYY-MM-DD-hhmm", timestamp())}"
  ami_description = "Golden AMI: Docker + AWS CLI + SSM + jq pre-installed"

  # Use existing subnet (default VPC has no public subnets)
  subnet_id                   = var.subnet_id
  associate_public_ip_address = true

  source_ami_filter {
    filters = {
      name                = "al2023-ami-*-x86_64"
      virtualization-type = "hvm"
      root-device-type    = "ebs"
    }
    most_recent = true
    owners      = ["amazon"]
  }

  ssh_username = "ec2-user"

  launch_block_device_mappings {
    device_name           = "/dev/xvda"
    volume_size           = 30
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  tags = {
    Name      = "${var.ami_name_prefix}"
    ManagedBy = "Packer"
    BuildDate = formatdate("YYYY-MM-DD", timestamp())
  }
}

build {
  name    = "base-ami"
  sources = ["source.amazon-ebs.base"]

  # System updates
  provisioner "shell" {
    inline = [
      "sudo dnf update -y"
    ]
  }

  # Docker
  provisioner "shell" {
    inline = [
      "sudo dnf install -y docker",
      "sudo systemctl enable docker",
      "sudo systemctl start docker",
      "sudo usermod -aG docker ec2-user",
      "docker --version"
    ]
  }

  # AWS CLI v2
  provisioner "shell" {
    inline = [
      "sudo dnf install -y unzip",
      "curl -s 'https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip' -o /tmp/awscliv2.zip",
      "unzip -q /tmp/awscliv2.zip -d /tmp",
      "sudo /tmp/aws/install --update",
      "rm -rf /tmp/aws /tmp/awscliv2.zip",
      "aws --version"
    ]
  }

  # jq (needed to parse release manifest JSON at boot)
  provisioner "shell" {
    inline = [
      "sudo dnf install -y jq",
      "jq --version"
    ]
  }

  # SSM Agent
  provisioner "shell" {
    inline = [
      "sudo dnf install -y amazon-ssm-agent 2>/dev/null || true",
      "sudo systemctl enable amazon-ssm-agent"
    ]
  }

  # CloudWatch Agent
  provisioner "shell" {
    inline = [
      "sudo dnf install -y amazon-cloudwatch-agent"
    ]
  }

  # Pre-pull Python slim base image (speeds up app container pull)
  provisioner "shell" {
    inline = [
      "sudo docker pull python:3.12-slim || true"
    ]
  }

  # Cleanup
  provisioner "shell" {
    inline = [
      "sudo dnf clean all",
      "sudo rm -rf /tmp/*",
      "sudo rm -f /home/ec2-user/.ssh/authorized_keys",
      "sudo cloud-init clean --logs"
    ]
  }

  post-processor "manifest" {
    output     = "packer-manifest.json"
    strip_path = true
  }

  post-processor "shell-local" {
    inline = [
      "echo ",
      "echo ═══════════════════════════════════════════════════",
      "echo   GOLDEN AMI CREATED SUCCESSFULLY",
      "echo ═══════════════════════════════════════════════════",
      "echo   AMI ID:  ${build.ID}",
      "echo   Region:  ${var.region}",
      "echo ═══════════════════════════════════════════════════",
      "echo ",
      "echo   Next step:",
      "echo   export BASE_AMI_ID=${build.ID}",
      "echo   bash scripts/setup-infra.sh",
      "echo ═══════════════════════════════════════════════════"
    ]
  }
}
