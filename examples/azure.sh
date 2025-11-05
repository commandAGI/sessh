#!/bin/bash
# Example: Using sessh with Microsoft Azure Virtual Machines
# This demonstrates launching an Azure VM, using sessh to train a model, and terminating it
set -euo pipefail

# Configuration
export AZURE_RESOURCE_GROUP="${AZURE_RESOURCE_GROUP:-sessh-example-rg}"
export AZURE_LOCATION="${AZURE_LOCATION:-eastus}"
export AZURE_VM_SIZE="${AZURE_VM_SIZE:-Standard_B1s}"
export AZURE_VM_NAME="${AZURE_VM_NAME:-sessh-example-$(date +%s)}"
export AZURE_IMAGE="${AZURE_IMAGE:-Ubuntu2204}"
ALIAS="azure-agent"

# Check prerequisites
command -v az >/dev/null 2>&1 || { echo "Error: Azure CLI is required but not installed." >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "Error: jq is required but not installed." >&2; exit 1; }

# Check if logged in
if ! az account show >/dev/null 2>&1; then
  echo "Error: Not logged in to Azure. Run 'az login' first." >&2
  exit 1
fi

IP=""
CLEANUP_RG=false

cleanup() {
  echo "Cleaning up..."
  if [[ -n "$ALIAS" ]] && [[ -n "$IP" ]]; then
    sessh close "$ALIAS" "azureuser@${IP}" 2>/dev/null || true
  fi
  if [[ -n "$AZURE_VM_NAME" ]]; then
    echo "Deleting Azure VM: $AZURE_VM_NAME"
    az vm delete \
      --resource-group "$AZURE_RESOURCE_GROUP" \
      --name "$AZURE_VM_NAME" \
      --yes >/dev/null 2>&1 || true
  fi
  if [[ "$CLEANUP_RG" == "true" ]]; then
    echo "Deleting resource group: $AZURE_RESOURCE_GROUP"
    az group delete --name "$AZURE_RESOURCE_GROUP" --yes --no-wait >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

echo "=== Azure VM Sessh Example ==="
echo "Resource Group: $AZURE_RESOURCE_GROUP"
echo "Location: $AZURE_LOCATION"
echo "VM Size: $AZURE_VM_SIZE"
echo "VM Name: $AZURE_VM_NAME"
echo ""

# Check if resource group exists, create if not
if ! az group show --name "$AZURE_RESOURCE_GROUP" >/dev/null 2>&1; then
  echo "Creating resource group..."
  az group create --name "$AZURE_RESOURCE_GROUP" --location "$AZURE_LOCATION" >/dev/null
  CLEANUP_RG=true
fi

# Generate SSH key if needed
SSH_KEY_PATH="$HOME/.ssh/id_rsa"
if [[ ! -f "$SSH_KEY_PATH" ]]; then
  echo "Generating SSH key..."
  ssh-keygen -t rsa -b 4096 -f "$SSH_KEY_PATH" -N "" -q
fi

# Launch VM
echo "Creating Azure VM..."
az vm create \
  --resource-group "$AZURE_RESOURCE_GROUP" \
  --name "$AZURE_VM_NAME" \
  --image "$AZURE_IMAGE" \
  --size "$AZURE_VM_SIZE" \
  --admin-username azureuser \
  --ssh-key-values "$SSH_KEY_PATH.pub" \
  --public-ip-sku Standard \
  --output json > /tmp/azure-vm-output.json

# Get IP address
IP=$(jq -r '.publicIpAddress' /tmp/azure-vm-output.json)

if [[ -z "$IP" ]] || [[ "$IP" == "null" ]]; then
  echo "Error: Failed to get VM IP address." >&2
  exit 1
fi

echo "VM IP: $IP"

# Wait for SSH to be ready
echo "Waiting for SSH to be ready..."
for i in {1..60}; do
  if ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new -i "$SSH_KEY_PATH" "azureuser@${IP}" "echo ready" 2>/dev/null; then
    break
  fi
  sleep 5
done

# Open session
echo "Opening sessh session..."
export SESSH_IDENTITY="$SSH_KEY_PATH"
sessh open "$ALIAS" "azureuser@${IP}"

# Install dependencies and run workload
echo "Installing dependencies..."
sessh run "$ALIAS" "azureuser@${IP}" -- "sudo apt-get update -qq"
sessh run "$ALIAS" "azureuser@${IP}" -- "sudo apt-get install -y -qq python3-pip tmux"

echo "Running workload..."
sessh run "$ALIAS" "azureuser@${IP}" -- "python3 -c 'import sys; print(f\"Python version: {sys.version}\")'"
sessh run "$ALIAS" "azureuser@${IP}" -- "cd /tmp && pwd && echo 'Working directory: $(pwd)' && echo 'State persisted across commands!'"

# Get logs
echo ""
echo "=== Session Logs ==="
sessh logs "$ALIAS" "azureuser@${IP}" 100

# Check status
echo ""
echo "=== Session Status ==="
sessh status "$ALIAS" "azureuser@${IP}"

echo ""
echo "Example completed successfully!"
echo "VM $AZURE_VM_NAME will be deleted on exit."

