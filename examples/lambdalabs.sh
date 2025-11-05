#!/bin/bash
# Example: Using sessh with Lambda Labs GPU instances
# This demonstrates launching a Lambda Labs GPU instance, using sessh to train a model, and terminating it
set -euo pipefail

# Configuration
export LAMBDA_API_KEY="${LAMBDA_API_KEY:-}"
export LAMBDA_REGION="${LAMBDA_REGION:-us-west-1}"
export LAMBDA_INSTANCE_TYPE="${LAMBDA_INSTANCE_TYPE:-gpu_1x_a10}"
export LAMBDA_SSH_KEY="${LAMBDA_SSH_KEY:-}"
ALIAS="lambda-agent"
SESSH_BIN="${SESSH_BIN:-sessh}"

# Check prerequisites
command -v jq >/dev/null 2>&1 || { echo "Error: jq is required but not installed." >&2; exit 1; }
command -v curl >/dev/null 2>&1 || { echo "Error: curl is required but not installed." >&2; exit 1; }

if [[ -z "$LAMBDA_API_KEY" ]]; then
  echo "Error: LAMBDA_API_KEY environment variable must be set with your Lambda Labs API key." >&2
  exit 1
fi

if [[ -z "$LAMBDA_SSH_KEY" ]]; then
  echo "Error: LAMBDA_SSH_KEY environment variable must be set with your Lambda Labs SSH key name." >&2
  exit 1
fi

INSTANCE_ID=""
IP=""

cleanup() {
  echo "Cleaning up..."
  if [[ -n "$ALIAS" ]] && [[ -n "$IP" ]]; then
    "$SESSH_BIN" close "$ALIAS" "ubuntu@${IP}" 2>/dev/null || true
  fi
  if [[ -n "$INSTANCE_ID" ]]; then
    echo "Terminating Lambda Labs instance: $INSTANCE_ID"
    curl -su "$LAMBDA_API_KEY:" \
      -H "content-type: application/json" \
      -X POST https://cloud.lambdalabs.com/api/v1/instance-operations/terminate \
      -d "{\"instance_ids\": [\"$INSTANCE_ID\"]}" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

echo "=== Lambda Labs GPU Sessh Example ==="
echo "Region: $LAMBDA_REGION"
echo "Instance Type: $LAMBDA_INSTANCE_TYPE"
echo "SSH Key: $LAMBDA_SSH_KEY"
echo ""

# Launch instance
echo "Launching Lambda Labs instance..."
RESPONSE=$(curl -su "$LAMBDA_API_KEY:" \
  -H "content-type: application/json" \
  -X POST https://cloud.lambdalabs.com/api/v1/instance-operations/launch \
  -d "{\"region_name\":\"$LAMBDA_REGION\",\"instance_type_name\":\"$LAMBDA_INSTANCE_TYPE\",\"ssh_key_names\":[\"$LAMBDA_SSH_KEY\"],\"quantity\":1}")

if ! echo "$RESPONSE" | jq -e '.data.instance_ids[0]' >/dev/null 2>&1; then
  echo "Error: Failed to launch instance. Response: $RESPONSE" >&2
  exit 1
fi

INSTANCE_ID=$(echo "$RESPONSE" | jq -r '.data.instance_ids[0]')
echo "Instance ID: $INSTANCE_ID"

# Wait for IP
echo "Waiting for instance IP address..."
for i in {1..60}; do
  INSTANCES=$(curl -su "$LAMBDA_API_KEY:" \
    https://cloud.lambdalabs.com/api/v1/instances 2>/dev/null)
  
  IP=$(echo "$INSTANCES" | jq -r ".data[] | select(.id==\"$INSTANCE_ID\") | .ip")
  
  if [[ "$IP" != "null" ]] && [[ -n "$IP" ]] && [[ "$IP" != "" ]]; then
    break
  fi
  sleep 5
done

if [[ "$IP" == "null" ]] || [[ -z "$IP" ]]; then
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
"$SESSH_BIN" open "$ALIAS" "ubuntu@${IP}"

# Install dependencies and run workload
echo "Installing dependencies..."
"$SESSH_BIN" run "$ALIAS" "ubuntu@${IP}" -- "pip install torch torchvision"
"$SESSH_BIN" run "$ALIAS" "ubuntu@${IP}" -- "python3 -c 'import torch; print(f"PyTorch version: {torch.__version__}")'"

echo "Running workload..."
"$SESSH_BIN" run "$ALIAS" "ubuntu@${IP}" -- "cd /tmp && pwd && echo 'Working directory: $(pwd)' && echo 'State persisted across commands!'"
"$SESSH_BIN" run "$ALIAS" "ubuntu@${IP}" -- "nvidia-smi || echo 'GPU check (may not be available in all instance types)'"

# Get logs
echo ""
echo "=== Session Logs ==="
"$SESSH_BIN" logs "$ALIAS" "ubuntu@${IP}" 200

# Check status
echo ""
echo "=== Session Status ==="
"$SESSH_BIN" status "$ALIAS" "ubuntu@${IP}"

echo ""
echo "Example completed successfully!"
echo "Instance $INSTANCE_ID will be terminated on exit."

