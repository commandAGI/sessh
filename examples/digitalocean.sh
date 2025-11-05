#!/bin/bash
# Example: Using sessh with DigitalOcean Droplets
# This demonstrates launching a DigitalOcean droplet, using sessh to train a model, and terminating it
set -euo pipefail

# Configuration
export DO_TOKEN="${DO_TOKEN:-}"
export DO_REGION="${DO_REGION:-nyc1}"
export DO_SIZE="${DO_SIZE:-s-1vcpu-1gb}"
export DO_IMAGE="${DO_IMAGE:-ubuntu-22-04-x64}"
DROPLET_NAME="sessh-example-$(date +%s)"
ALIAS="do-agent"

# Check prerequisites
command -v doctl >/dev/null 2>&1 || { echo "Error: doctl CLI is required but not installed." >&2; exit 1; }

if [[ -z "$DO_TOKEN" ]]; then
  echo "Error: DO_TOKEN environment variable must be set with your DigitalOcean API token." >&2
  echo "Get one at: https://cloud.digitalocean.com/account/api/tokens" >&2
  exit 1
fi

# Authenticate doctl
doctl auth init --access-token "$DO_TOKEN" >/dev/null 2>&1 || true

# Generate SSH key if needed
SSH_KEY_PATH="$HOME/.ssh/id_ed25519"
if [[ ! -f "$SSH_KEY_PATH" ]]; then
  echo "Generating SSH key..."
  ssh-keygen -t ed25519 -f "$SSH_KEY_PATH" -N "" -q
fi

# Add SSH key to DigitalOcean if not already present
SSH_KEY_NAME="sessh-key"
SSH_FINGERPRINT=$(ssh-keygen -l -f "$SSH_KEY_PATH.pub" -E md5 | awk '{print $2}' | sed 's/MD5://')
EXISTING_KEY=$(doctl compute ssh-key list --format ID,Fingerprint --no-header 2>/dev/null | grep -i "$SSH_FINGERPRINT" || true)

if [[ -z "$EXISTING_KEY" ]]; then
  echo "Adding SSH key to DigitalOcean..."
  doctl compute ssh-key create "$SSH_KEY_NAME" --public-key-file "$SSH_KEY_PATH.pub" >/dev/null 2>&1 || true
fi

DROPLET_ID=""
IP=""

cleanup() {
  echo "Cleaning up..."
  if [[ -n "$ALIAS" ]] && [[ -n "$IP" ]]; then
    sessh close "$ALIAS" "root@${IP}" 2>/dev/null || true
  fi
  if [[ -n "$DROPLET_ID" ]]; then
    echo "Deleting DigitalOcean droplet: $DROPLET_ID"
    doctl compute droplet delete "$DROPLET_ID" --force >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

echo "=== DigitalOcean Droplet Sessh Example ==="
echo "Region: $DO_REGION"
echo "Size: $DO_SIZE"
echo "Image: $DO_IMAGE"
echo ""

# Launch droplet
echo "Creating DigitalOcean droplet..."
DROPLET_OUTPUT=$(doctl compute droplet create "$DROPLET_NAME" \
  --region "$DO_REGION" \
  --size "$DO_SIZE" \
  --image "$DO_IMAGE" \
  --ssh-keys "$SSH_FINGERPRINT" \
  --format ID,PublicIPv4 \
  --no-header)

DROPLET_ID=$(echo "$DROPLET_OUTPUT" | awk '{print $1}')

if [[ -z "$DROPLET_ID" ]]; then
  echo "Error: Failed to create droplet." >&2
  exit 1
fi

echo "Droplet ID: $DROPLET_ID"

# Wait for droplet to be active and get IP
echo "Waiting for droplet to be active..."
for i in {1..60}; do
  DROPLET_INFO=$(doctl compute droplet get "$DROPLET_ID" --format ID,Status,PublicIPv4 --no-header 2>/dev/null || echo "")
  
  if [[ -n "$DROPLET_INFO" ]]; then
    STATUS=$(echo "$DROPLET_INFO" | awk '{print $2}')
    IP=$(echo "$DROPLET_INFO" | awk '{print $3}')
    
    if [[ "$STATUS" == "active" ]] && [[ -n "$IP" ]] && [[ "$IP" != "none" ]]; then
      break
    fi
  fi
  sleep 5
done

if [[ -z "$IP" ]] || [[ "$IP" == "none" ]]; then
  echo "Error: Failed to get droplet IP address." >&2
  exit 1
fi

echo "Droplet IP: $IP"

# Wait for SSH to be ready
echo "Waiting for SSH to be ready..."
for i in {1..60}; do
  if ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new -i "$SSH_KEY_PATH" "root@${IP}" "echo ready" 2>/dev/null; then
    break
  fi
  sleep 5
done

# Open session
echo "Opening sessh session..."
export SESSH_IDENTITY="$SSH_KEY_PATH"
sessh open "$ALIAS" "root@${IP}"

# Install dependencies and run workload
echo "Installing dependencies..."
sessh run "$ALIAS" "root@${IP}" -- "apt-get update -qq"
sessh run "$ALIAS" "root@${IP}" -- "apt-get install -y -qq python3-pip tmux"

echo "Running workload..."
sessh run "$ALIAS" "root@${IP}" -- "python3 -c 'import sys; print(f\"Python version: {sys.version}\")'"
sessh run "$ALIAS" "root@${IP}" -- "cd /tmp && pwd && echo 'Working directory: $(pwd)' && echo 'State persisted across commands!'"

# Get logs
echo ""
echo "=== Session Logs ==="
sessh logs "$ALIAS" "root@${IP}" 100

# Check status
echo ""
echo "=== Session Status ==="
sessh status "$ALIAS" "root@${IP}"

echo ""
echo "Example completed successfully!"
echo "Droplet $DROPLET_ID will be deleted on exit."

