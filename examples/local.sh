#!/bin/bash
# Example: Using sessh with a localhost or local VM
# This demonstrates sessh usage on a local machine or VM accessible via SSH
set -euo pipefail

# Configuration
HOST="${1:-localhost}"
USER="${USER:-$(whoami)}"
ALIAS="local-test"

cleanup() {
  echo "Cleaning up..."
  SESSH_BIN="${SESSH_BIN:-sessh}"
  "$SESSH_BIN" close "$ALIAS" "${USER}@${HOST}" 2>/dev/null || true
}
trap cleanup EXIT

echo "=== Local Sessh Example ==="
echo "Host: ${USER}@${HOST}"
echo ""

# Ensure tmux is installed on remote (if not localhost)
if [[ "$HOST" != "localhost" ]] && [[ "$HOST" != "127.0.0.1" ]]; then
  echo "Installing tmux on remote host..."
  ssh "${USER}@${HOST}" "command -v tmux >/dev/null 2>&1 || sudo apt-get update && sudo apt-get install -y tmux" || true
fi

# Open session
echo "Opening sessh session..."
SESSH_BIN="${SESSH_BIN:-sessh}"
"$SESSH_BIN" open "$ALIAS" "${USER}@${HOST}"

# Run commands
echo "Running commands..."
"$SESSH_BIN" run "$ALIAS" "${USER}@${HOST}" -- "echo 'Hello from sessh!'"
"$SESSH_BIN" run "$ALIAS" "${USER}@${HOST}" -- "pwd"
"$SESSH_BIN" run "$ALIAS" "${USER}@${HOST}" -- "whoami"
"$SESSH_BIN" run "$ALIAS" "${USER}@${HOST}" -- "cd /tmp && pwd && echo 'State persisted!'"

# Get logs
echo ""
echo "=== Session Logs ==="
"$SESSH_BIN" logs "$ALIAS" "${USER}@${HOST}" 50

# Check status
echo ""
echo "=== Session Status ==="
"$SESSH_BIN" status "$ALIAS" "${USER}@${HOST}"

echo ""
echo "Example completed successfully!"

