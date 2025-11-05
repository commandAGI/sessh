#!/bin/bash
# Example: Using sessh with a Docker container
# This demonstrates sessh usage with a Docker container that runs an SSH server
set -euo pipefail

# Configuration
CONTAINER_NAME="sessh-test-$(date +%s)"
IMAGE="ubuntu:22.04"
ALIAS="docker-test"
SSH_PORT="${SSH_PORT:-2222}"

cleanup() {
  echo "Cleaning up..."
  sessh close "$ALIAS" "root@localhost" "$SSH_PORT" 2>/dev/null || true
  docker stop "$CONTAINER_NAME" 2>/dev/null || true
  docker rm "$CONTAINER_NAME" 2>/dev/null || true
}
trap cleanup EXIT

echo "=== Docker Sessh Example ==="
echo "Container: $CONTAINER_NAME"
echo ""

# Check if Docker is available
command -v docker >/dev/null 2>&1 || { echo "Error: docker is required but not installed." >&2; exit 1; }

# Generate SSH key if needed
if [[ ! -f ~/.ssh/id_ed25519 ]]; then
  echo "Generating SSH key..."
  ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -N "" -q
fi

# Start Docker container with SSH server
echo "Starting Docker container with SSH server..."
docker run -d \
  --name "$CONTAINER_NAME" \
  -p "${SSH_PORT}:22" \
  -e "SSH_PUBKEY=$(cat ~/.ssh/id_ed25519.pub)" \
  "$IMAGE" \
  bash -c "
    apt-get update -qq && \
    apt-get install -y -qq openssh-server tmux sudo && \
    mkdir -p /var/run/sshd && \
    echo 'root:testpass' | chpasswd && \
    sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin yes/' /etc/ssh/sshd_config && \
    mkdir -p /root/.ssh && \
    echo \"\${SSH_PUBKEY}\" > /root/.ssh/authorized_keys && \
    chmod 700 /root/.ssh && \
    chmod 600 /root/.ssh/authorized_keys && \
    /usr/sbin/sshd -D
  "

# Wait for container to be ready
echo "Waiting for SSH server to be ready..."
sleep 5
for i in {1..30}; do
  if ssh -o ConnectTimeout=2 -o StrictHostKeyChecking=no -p "$SSH_PORT" root@localhost "echo ready" 2>/dev/null; then
    break
  fi
  sleep 2
done

# Open session
echo "Opening sessh session..."
sessh open "$ALIAS" "root@localhost" "$SSH_PORT"

# Run commands
echo "Running commands..."
sessh run "$ALIAS" "root@localhost" "$SSH_PORT" -- "echo 'Hello from Docker container!'"
sessh run "$ALIAS" "root@localhost" "$SSH_PORT" -- "apt-get update -qq"
sessh run "$ALIAS" "root@localhost" "$SSH_PORT" -- "which tmux"
sessh run "$ALIAS" "root@localhost" "$SSH_PORT" -- "cd /tmp && pwd && echo 'State persisted across commands!'"

# Get logs
echo ""
echo "=== Session Logs ==="
sessh logs "$ALIAS" "root@localhost" "$SSH_PORT" 50

# Check status
echo ""
echo "=== Session Status ==="
sessh status "$ALIAS" "root@localhost" "$SSH_PORT"

echo ""
echo "Example completed successfully!"

