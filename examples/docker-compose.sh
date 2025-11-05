#!/bin/bash
# Example: Using sessh with Docker Compose
# This demonstrates using sessh with services defined in docker-compose.yml
set -euo pipefail

# Configuration
COMPOSE_FILE="${COMPOSE_FILE:-docker-compose.yml}"
SERVICE_NAME="${SERVICE_NAME:-test-service}"
ALIAS="compose-test"
SSH_PORT="${SSH_PORT:-2222}"

cleanup() {
  echo "Cleaning up..."
  if [[ -n "$ALIAS" ]] && [[ -n "$SERVICE_NAME" ]]; then
    sessh close "$ALIAS" "root@localhost" "$SSH_PORT" 2>/dev/null || true
  fi
  if [[ -f "$COMPOSE_FILE" ]]; then
    echo "Stopping Docker Compose services..."
    docker-compose -f "$COMPOSE_FILE" down >/dev/null 2>&1 || true
  fi
  rm -f "$COMPOSE_FILE"
}
trap cleanup EXIT

echo "=== Docker Compose Sessh Example ==="
echo "Service: $SERVICE_NAME"
echo ""

# Check if Docker Compose is available
command -v docker-compose >/dev/null 2>&1 || { echo "Error: docker-compose is required but not installed." >&2; exit 1; }

# Generate SSH key if needed
if [[ ! -f ~/.ssh/id_ed25519 ]]; then
  echo "Generating SSH key..."
  ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -N "" -q
fi

# Create docker-compose.yml
cat > "$COMPOSE_FILE" <<EOF
version: '3.8'
services:
  $SERVICE_NAME:
    image: ubuntu:22.04
    ports:
      - "${SSH_PORT}:22"
    environment:
      - SSH_PUBKEY=$(cat ~/.ssh/id_ed25519.pub)
    command: >
      bash -c "
        apt-get update -qq &&
        apt-get install -y -qq openssh-server tmux sudo &&
        mkdir -p /var/run/sshd &&
        echo 'root:testpass' | chpasswd &&
        sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin yes/' /etc/ssh/sshd_config &&
        mkdir -p /root/.ssh &&
        echo \"\${SSH_PUBKEY}\" > /root/.ssh/authorized_keys &&
        chmod 700 /root/.ssh &&
        chmod 600 /root/.ssh/authorized_keys &&
        /usr/sbin/sshd -D
      "
EOF

# Start services
echo "Starting Docker Compose services..."
docker-compose -f "$COMPOSE_FILE" up -d

# Wait for SSH to be ready
echo "Waiting for SSH server to be ready..."
for i in {1..30}; do
  if ssh -o ConnectTimeout=2 -o StrictHostKeyChecking=no -p "$SSH_PORT" root@localhost "echo ready" 2>/dev/null; then
    break
  fi
  sleep 2
done

# Get container info
CONTAINER_ID=$(docker-compose -f "$COMPOSE_FILE" ps -q "$SERVICE_NAME")
echo "Container ID: $CONTAINER_ID"

# Open session
echo "Opening sessh session..."
sessh open "$ALIAS" "root@localhost" "$SSH_PORT"

# Run commands
echo "Running commands..."
sessh run "$ALIAS" "root@localhost" "$SSH_PORT" -- "echo 'Hello from Docker Compose service!'"
sessh run "$ALIAS" "root@localhost" "$SSH_PORT" -- "hostname"
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

# Show Docker Compose status
echo ""
echo "=== Docker Compose Status ==="
docker-compose -f "$COMPOSE_FILE" ps

echo ""
echo "Example completed successfully!"

