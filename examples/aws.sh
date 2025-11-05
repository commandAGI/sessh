#!/bin/bash
# Example: Using sessh with AWS EC2
# This demonstrates launching an EC2 instance, using sessh to train a model, and terminating it
set -euo pipefail

# Configuration
export AWS_REGION="${AWS_REGION:-us-east-1}"
export INSTANCE_TYPE="${INSTANCE_TYPE:-t2.micro}"
export KEY_NAME="${AWS_KEY_NAME:-}"
export SECURITY_GROUP="${AWS_SECURITY_GROUP:-}"
export AMI_ID="${AWS_AMI_ID:-}"  # e.g., ubuntu/images/h-u-22.04-amd64-server-*
ALIAS="aws-agent"

# Check prerequisites
command -v aws >/dev/null 2>&1 || { echo "Error: AWS CLI is required but not installed." >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "Error: jq is required but not installed." >&2; exit 1; }

# Get default values if not set
if [[ -z "$KEY_NAME" ]]; then
  KEY_NAME=$(aws ec2 describe-key-pairs --query 'KeyPairs[0].KeyName' --output text 2>/dev/null || echo "")
  if [[ -z "$KEY_NAME" ]]; then
    echo "Error: AWS_KEY_NAME must be set or at least one key pair must exist." >&2
    exit 1
  fi
fi

if [[ -z "$AMI_ID" ]]; then
  AMI_ID=$(aws ec2 describe-images \
    --owners 099720109477 \
    --filters "Name=name,Values=ubuntu/images/h2-ssd/ubuntu-jammy-22.04-amd64-server-*" \
              "Name=state,Values=available" \
    --query 'Images | sort_by(@, &CreationDate) | [-1].ImageId' \
    --output text \
    --region "$AWS_REGION")
fi

if [[ -z "$SECURITY_GROUP" ]]; then
  # Try to find a security group that allows SSH
  SECURITY_GROUP=$(aws ec2 describe-security-groups \
    --filters "Name=ip-permission.from-port,Values=22" \
              "Name=ip-permission.to-port,Values=22" \
              "Name=ip-permission.protocol,Values=tcp" \
    --query 'SecurityGroups[0].GroupId' \
    --output text \
    --region "$AWS_REGION" 2>/dev/null || echo "")
  
  if [[ -z "$SECURITY_GROUP" ]]; then
    echo "Error: AWS_SECURITY_GROUP must be set or a security group allowing SSH must exist." >&2
    exit 1
  fi
fi

INSTANCE_ID=""
IP=""

cleanup() {
  echo "Cleaning up..."
  if [[ -n "$ALIAS" ]] && [[ -n "$IP" ]]; then
    sessh close "$ALIAS" "ubuntu@${IP}" 2>/dev/null || true
  fi
  if [[ -n "$INSTANCE_ID" ]]; then
    echo "Terminating EC2 instance: $INSTANCE_ID"
    aws ec2 terminate-instances --instance-ids "$INSTANCE_ID" --region "$AWS_REGION" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

echo "=== AWS EC2 Sessh Example ==="
echo "Region: $AWS_REGION"
echo "Instance Type: $INSTANCE_TYPE"
echo "AMI: $AMI_ID"
echo "Key Name: $KEY_NAME"
echo "Security Group: $SECURITY_GROUP"
echo ""

# Launch instance
echo "Launching EC2 instance..."
LAUNCH_OUTPUT=$(aws ec2 run-instances \
  --image-id "$AMI_ID" \
  --instance-type "$INSTANCE_TYPE" \
  --key-name "$KEY_NAME" \
  --security-group-ids "$SECURITY_GROUP" \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=sessh-example}]" \
  --region "$AWS_REGION" \
  --output json)

INSTANCE_ID=$(echo "$LAUNCH_OUTPUT" | jq -r '.Instances[0].InstanceId')
echo "Instance ID: $INSTANCE_ID"

# Wait for instance to be running
echo "Waiting for instance to be running..."
aws ec2 wait instance-running --instance-ids "$INSTANCE_ID" --region "$AWS_REGION"

# Get IP address
echo "Getting instance IP address..."
for i in {1..30}; do
  IP=$(aws ec2 describe-instances \
    --instance-ids "$INSTANCE_ID" \
    --query 'Reservations[0].Instances[0].PublicIpAddress' \
    --output text \
    --region "$AWS_REGION")
  
  if [[ "$IP" != "None" ]] && [[ -n "$IP" ]]; then
    break
  fi
  sleep 2
done

if [[ "$IP" == "None" ]] || [[ -z "$IP" ]]; then
  echo "Error: Failed to get instance IP address." >&2
  exit 1
fi

echo "Instance IP: $IP"

# Wait for SSH to be ready
echo "Waiting for SSH to be ready..."
for i in {1..60}; do
  if ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new "ubuntu@${IP}" "echo ready" 2>/dev/null; then
    break
  fi
  sleep 5
done

# Open session
echo "Opening sessh session..."
sessh open "$ALIAS" "ubuntu@${IP}"

# Install dependencies and run workload
echo "Installing dependencies..."
sessh run "$ALIAS" "ubuntu@${IP}" -- "sudo apt-get update -qq"
sessh run "$ALIAS" "ubuntu@${IP}" -- "sudo apt-get install -y -qq python3-pip tmux"

echo "Running workload..."
sessh run "$ALIAS" "ubuntu@${IP}" -- "python3 -c 'import sys; print(f\"Python version: {sys.version}\")'"
sessh run "$ALIAS" "ubuntu@${IP}" -- "cd /tmp && pwd && echo 'Working directory: $(pwd)' && echo 'State persisted across commands!'"

# Get logs
echo ""
echo "=== Session Logs ==="
sessh logs "$ALIAS" "ubuntu@${IP}" 100

# Check status
echo ""
echo "=== Session Status ==="
sessh status "$ALIAS" "ubuntu@${IP}"

echo ""
echo "Example completed successfully!"
echo "Instance $INSTANCE_ID will be terminated on exit."

