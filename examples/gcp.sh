#!/bin/bash
# Example: Using sessh with Google Cloud Platform Compute Engine
# This demonstrates launching a GCP instance, using sessh to train a model, and terminating it
set -euo pipefail

# Configuration
export GCP_PROJECT="${GCP_PROJECT:-}"
export GCP_ZONE="${GCP_ZONE:-us-central1-a}"
export INSTANCE_TYPE="${GCP_INSTANCE_TYPE:-n1-standard-1}"
export IMAGE_PROJECT="${GCP_IMAGE_PROJECT:-ubuntu-os-cloud}"
export IMAGE_FAMILY="${GCP_IMAGE_FAMILY:-ubuntu-2204-lts}"
INSTANCE_NAME="sessh-example-$(date +%s)"
ALIAS="gcp-agent"
SESSH_BIN="${SESSH_BIN:-sessh}"

# Check prerequisites
command -v gcloud >/dev/null 2>&1 || { echo "Error: gcloud CLI is required but not installed." >&2; exit 1; }

if [[ -z "$GCP_PROJECT" ]]; then
  GCP_PROJECT=$(gcloud config get-value project 2>/dev/null || echo "")
  if [[ -z "$GCP_PROJECT" ]]; then
    echo "Error: GCP_PROJECT must be set or gcloud must be configured." >&2
    exit 1
  fi
fi

IP=""

cleanup() {
  echo "Cleaning up..."
  if [[ -n "$ALIAS" ]] && [[ -n "$IP" ]]; then
    "$SESSH_BIN" close "$ALIAS" "ubuntu@${IP}" 2>/dev/null || true
  fi
  if [[ -n "$INSTANCE_NAME" ]]; then
    echo "Deleting GCP instance: $INSTANCE_NAME"
    gcloud compute instances delete "$INSTANCE_NAME" \
      --zone="$GCP_ZONE" \
      --project="$GCP_PROJECT" \
      --quiet >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

echo "=== GCP Compute Engine Sessh Example ==="
echo "Project: $GCP_PROJECT"
echo "Zone: $GCP_ZONE"
echo "Instance Type: $INSTANCE_TYPE"
echo "Image: $IMAGE_PROJECT/$IMAGE_FAMILY"
echo ""

# Launch instance
echo "Creating GCP instance..."
gcloud compute instances create "$INSTANCE_NAME" \
  --zone="$GCP_ZONE" \
  --machine-type="$INSTANCE_TYPE" \
  --image-project="$IMAGE_PROJECT" \
  --image-family="$IMAGE_FAMILY" \
  --project="$GCP_PROJECT" \
  --metadata=enable-oslogin=FALSE \
  --tags=sessh-example

# Get IP address
echo "Getting instance IP address..."
for i in {1..30}; do
  IP=$(gcloud compute instances describe "$INSTANCE_NAME" \
    --zone="$GCP_ZONE" \
    --project="$GCP_PROJECT" \
    --format='get(networkInterfaces[0].accessConfigs[0].natIP)' 2>/dev/null || echo "")
  
  if [[ -n "$IP" ]] && [[ "$IP" != "None" ]]; then
    break
  fi
  sleep 2
done

if [[ -z "$IP" ]] || [[ "$IP" == "None" ]]; then
  echo "Error: Failed to get instance IP address." >&2
  exit 1
fi

echo "Instance IP: $IP"

# Wait for SSH to be ready
echo "Waiting for SSH to be ready..."
for i in {1..60}; do
  if gcloud compute ssh "$INSTANCE_NAME" \
    --zone="$GCP_ZONE" \
    --project="$GCP_PROJECT" \
    --command="echo ready" \
    --quiet >/dev/null 2>&1; then
    break
  fi
  sleep 5
done

# For sessh, we need to use the IP directly
# Wait for direct SSH access
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
"$SESSH_BIN" run "$ALIAS" "ubuntu@${IP}" -- "sudo apt-get update -qq"
"$SESSH_BIN" run "$ALIAS" "ubuntu@${IP}" -- "sudo apt-get install -y -qq python3-pip tmux"

echo "Running workload..."
"$SESSH_BIN" run "$ALIAS" "ubuntu@${IP}" -- "python3 -c 'import sys; print(f\"Python version: {sys.version}\")'"
"$SESSH_BIN" run "$ALIAS" "ubuntu@${IP}" -- "cd /tmp && pwd && echo 'Working directory: $(pwd)' && echo 'State persisted across commands!'"

# Get logs
echo ""
echo "=== Session Logs ==="
"$SESSH_BIN" logs "$ALIAS" "ubuntu@${IP}" 100

# Check status
echo ""
echo "=== Session Status ==="
"$SESSH_BIN" status "$ALIAS" "ubuntu@${IP}"

echo ""
echo "Example completed successfully!"
echo "Instance $INSTANCE_NAME will be deleted on exit."

