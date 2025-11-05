# Sessh - SSH Session Manager

A persistent SSH session manager that enables one-shot CLI commands to operate long-lived interactive shells on remote hosts. Perfect for AI agents like Cursor that can only run single commands.

## The Problem

AI coding assistants like Cursor can only run **single commands** that terminate immediately. But many workflows require **persistent interactive shells** that maintain state (current directory, environment variables, active processes) between commands.

Traditional SSH tools either:
- Require interactive sessions (not usable by AI agents)
- Run commands in isolation (no state persistence)
- Use complex connection management (hard to automate)

## The Solution

Sessh combines **SSH ControlMaster** (persistent connections) with **remote tmux** (persistent interactive shells) to give you:

- **Single-command interface**: Every command terminates immediately
- **Persistent state**: The remote shell maintains state between commands
- **AI agent friendly**: Perfect for Cursor and other MCP clients
- **Autonomous workflows**: Launch infrastructure → SSH → train models → terminate, all automatically

## Features

- **Persistent Sessions**: SSH ControlMaster/ControlPersist multiplexing with tmux on remote hosts
- **Autossh Support**: Automatic reconnection with keepalives
- **Ramfs Control Sockets**: Fast socket communication when available
- **Hardened SSH Options**: Modern KEX, ciphers, and MACs
- **JSON Output Mode**: Machine-friendly responses for automation
- **ProxyJump Support**: Jump through bastion hosts

## Installation

1. Copy `sessh` to your PATH and make it executable:
   ```bash
   cp sessh /usr/local/bin/
   chmod +x /usr/local/bin/sessh
   ```

2. Ensure prerequisites are installed:
   - `ssh` (OpenSSH client)
   - `tmux` (on remote hosts)
   - `jq` (optional, for JSON parsing)
   - `autossh` (optional, for auto-reconnection)

## Usage

```bash
# Open a persistent session
sessh open agent ubuntu@203.0.113.10

# Run a command in the session
sessh run agent ubuntu@203.0.113.10 -- "conda activate foo && python train.py"

# Get logs
sessh logs agent ubuntu@203.0.113.10 400

# Check status
sessh status agent ubuntu@203.0.113.10

# Attach interactively (Ctrl+B, D to detach)
sessh attach agent ubuntu@203.0.113.10

# Close session
sessh close agent ubuntu@203.0.113.10
```

## Environment Variables

- `SESSH_JSON=1` - Enable JSON output mode
- `SESSH_SSH=autossh` - Use autossh for auto-reconnection
- `SESSH_IDENTITY=~/.ssh/id_ed25519` - Specify SSH private key
- `SESSH_PROXYJUMP=user@bastion` - Use ProxyJump
- `SESSH_PERSIST=8h` - ControlMaster persistence duration
- `SESSH_KEEPALIVE=30` - Server alive interval (seconds)

## How It Works

Sessh combines two proven technologies:

### 1. SSH ControlMaster/ControlPersist

When you run `sessh open agent ubuntu@host`:
- Opens a persistent **master connection** to the remote host
- This connection stays alive for 8 hours (configurable)
- All subsequent commands **reuse** this connection (instant, no handshake)
- Control socket stored in ramfs (`/run/user/$UID`) when available for speed

### 2. Remote Tmux Session

On the remote host:
- Creates a **detached tmux session** named after your alias
- This session runs a real interactive shell
- Maintains state: current directory, environment variables, active processes
- Persists even when you disconnect

### Command Flow

When you run `sessh run agent ubuntu@host -- "command"`:

1. **Reuses master connection** (instant, no SSH handshake)
2. **Sends command via tmux**: `tmux send-keys -t agent "command" C-m`
3. **Returns immediately** (command runs in background tmux session)
4. **State persists**: Next command sees same cwd, same environment

When you run `sessh logs agent ubuntu@host`:

1. **Reuses master connection** (instant)
2. **Captures output**: `tmux capture-pane -pt agent -S -300`
3. **Returns output** (last 300 lines by default)

### Architecture Diagram

```
┌─────────────┐
│ AI Agent    │
│ (Cursor)    │
└──────┬──────┘
       │ single commands
       │ (terminate immediately)
       ▼
┌─────────────┐
│ sessh CLI   │
└──────┬──────┘
       │ SSH ControlMaster
       │ (persistent connection)
       ▼
┌─────────────────────┐
│ Remote Host         │
│ ┌─────────────────┐ │
│ │ tmux session    │ │
│ │ (persistent)    │ │
│ │ - maintains cwd │ │
│ │ - maintains env │ │
│ │ - runs commands │ │
│ └─────────────────┘ │
└─────────────────────┘
```

See [ARCHITECTURE.md](ARCHITECTURE.md) for detailed design documentation.

## Use Cases

### AI Agents (Primary Use Case)

Enable Cursor and other AI agents to fully manage remote infrastructure:

```bash
# Launch a Lambda Labs GPU instance
iid=$(curl -su "$LAMBDA_API_KEY:" ...)
ip=$(curl -su "$LAMBDA_API_KEY:" ...)

# Open session and train model
sessh open agent "ubuntu@$ip"
sessh run agent "ubuntu@$ip" -- "conda activate env && python train.py"
sessh logs agent "ubuntu@$ip" 400

# Terminate when done
curl -su "$LAMBDA_API_KEY:" ... --data '{"instance_ids": ["'$iid'"]}'
```

### Autonomous Workflows

Fully automated infrastructure management:

```bash
# Bootstrap EC2 instance
aws ec2 run-instances ... > /tmp/i.json
iid=$(jq -r '.Instances[0].InstanceId' /tmp/i.json)
aws ec2 wait instance-status-ok --instance-ids "$iid"
ip=$(aws ec2 describe-instances ... --query '...' --output text)

# Provision and train
sessh open agent "ubuntu@$ip"
sessh run agent "ubuntu@$ip" -- "sudo apt-get update && sudo apt-get install -y python3-pip"
sessh run agent "ubuntu@$ip" -- "pip install torch && python train.py"
sessh logs agent "ubuntu@$ip"
sessh close agent "ubuntu@$ip"

# Terminate
aws ec2 terminate-instances --instance-ids "$iid"
```

### CI/CD

Long-running jobs on remote infrastructure:

```bash
# Build and test on remote
sessh open builder "build@ci-host"
sessh run builder "build@ci-host" -- "cd /repo && make build"
sessh run builder "build@ci-host" -- "make test"
sessh logs builder "build@ci-host" 1000
```

### Development

Persistent remote development environments:

```bash
# Open session, work, detach, reattach later
sessh open dev "user@dev-server"
sessh attach dev "user@dev-server"  # Ctrl+B, D to detach
# ... later ...
sessh attach dev "user@dev-server"  # Resume where you left off
```

## Security

- Strict host key checking (default: `accept-new`)
- Key-only authentication (no passwords)
- Modern cipher suites and KEX algorithms
- Identity key isolation
- Control socket permissions

## Cross-Platform

Works on:
- Linux (primary)
- macOS (with Homebrew SSH/tmux)
- Windows (via WSL or Git Bash)

## Related Projects

- [sessh-mcp](https://github.com/CommandAGI/sessh-mcp) - MCP server for Cursor
- [sessh-python-sdk](https://github.com/CommandAGI/sessh-python-sdk) - Python SDK
- [sessh-typescript-sdk](https://github.com/CommandAGI/sessh-typescript-sdk) - TypeScript SDK

## License

MIT License - see LICENSE file for details.

## Examples

Comprehensive examples are available in the [`examples/`](examples/) directory. Each example demonstrates launching infrastructure, using sessh to manage persistent sessions, and cleaning up resources.

### Lambda Labs GPU Training

Complete example of launching a Lambda Labs GPU instance, training a model, and terminating:

```bash
#!/bin/bash
set -euo pipefail

export LAMBDA_API_KEY="sk_live_..."
export LAMBDA_REGION="us-west-1"
export LAMBDA_INSTANCE_TYPE="gpu_1x_h100_sxm5"
export LAMBDA_SSH_KEY="laptop-ed25519"

ALIAS="lambda-agent"
INSTANCE_ID=""
IP=""

cleanup() {
  echo "Cleaning up..."
  if [[ -n "$ALIAS" ]] && [[ -n "$IP" ]]; then
    sessh close "$ALIAS" "ubuntu@${IP}" 2>/dev/null || true
  fi
  if [[ -n "$INSTANCE_ID" ]]; then
    curl -su "$LAMBDA_API_KEY:" \
      -H "content-type: application/json" \
      -X POST https://cloud.lambdalabs.com/api/v1/instance-operations/terminate \
      -d "{\"instance_ids\": [\"$INSTANCE_ID\"]}" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

# Launch instance
echo "Launching Lambda Labs instance..."
RESPONSE=$(curl -su "$LAMBDA_API_KEY:" \
  -H "content-type: application/json" \
  -X POST https://cloud.lambdalabs.com/api/v1/instance-operations/launch \
  -d "{\"region_name\":\"$LAMBDA_REGION\",\"instance_type_name\":\"$LAMBDA_INSTANCE_TYPE\",\"ssh_key_names\":[\"$LAMBDA_SSH_KEY\"],\"quantity\":1}")

INSTANCE_ID=$(echo "$RESPONSE" | jq -r '.data.instance_ids[0]')
echo "Instance ID: $INSTANCE_ID"

# Wait for IP
echo "Waiting for instance IP address..."
until ip=$(curl -su "$LAMBDA_API_KEY:" \
  https://cloud.lambdalabs.com/api/v1/instances | \
  jq -r ".data[] | select(.id==\"$INSTANCE_ID\") | .ip") && [[ "$ip" != "null" ]]; do
  sleep 5
done
IP="$ip"
echo "Instance IP: $IP"

# Wait for SSH to be ready
echo "Waiting for SSH to be ready..."
for i in {1..60}; do
  if ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new "ubuntu@${IP}" "echo ready" 2>/dev/null; then
    break
  fi
  sleep 5
done

# Use sessh to train model
sessh open "$ALIAS" "ubuntu@${IP}"
sessh run "$ALIAS" "ubuntu@${IP}" -- "pip install torch torchvision"
sessh run "$ALIAS" "ubuntu@${IP}" -- "python train.py"
sessh logs "$ALIAS" "ubuntu@${IP}" 400

# Cleanup happens automatically via trap
```

**Run the full example:**
```bash
export LAMBDA_API_KEY="sk_live_..."
export LAMBDA_SSH_KEY="my-ssh-key-name"
./examples/lambdalabs.sh
```

### AWS EC2 Example

Complete example of launching an EC2 instance, using sessh, and terminating:

```bash
#!/bin/bash
set -euo pipefail

export AWS_REGION="${AWS_REGION:-us-east-1}"
export INSTANCE_TYPE="${INSTANCE_TYPE:-t2.micro}"
export AWS_KEY_NAME="${AWS_KEY_NAME:-}"
export AWS_SECURITY_GROUP="${AWS_SECURITY_GROUP:-}"
ALIAS="aws-agent"

# Launch instance
LAUNCH_OUTPUT=$(aws ec2 run-instances \
  --image-id ami-xxxxx \
  --instance-type "$INSTANCE_TYPE" \
  --key-name "$AWS_KEY_NAME" \
  --security-group-ids "$AWS_SECURITY_GROUP" \
  --region "$AWS_REGION" \
  --output json)

INSTANCE_ID=$(echo "$LAUNCH_OUTPUT" | jq -r '.Instances[0].InstanceId')

# Wait for instance to be running
aws ec2 wait instance-running --instance-ids "$INSTANCE_ID" --region "$AWS_REGION"

# Get IP address
IP=$(aws ec2 describe-instances \
  --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' \
  --output text \
  --region "$AWS_REGION")

# Wait for SSH to be ready
for i in {1..60}; do
  if ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new "ubuntu@${IP}" "echo ready" 2>/dev/null; then
    break
  fi
  sleep 5
done

# Use sessh
sessh open "$ALIAS" "ubuntu@${IP}"
sessh run "$ALIAS" "ubuntu@${IP}" -- "sudo apt-get update -qq"
sessh run "$ALIAS" "ubuntu@${IP}" -- "python3 train.py"
sessh logs "$ALIAS" "ubuntu@${IP}" 400

# Terminate
sessh close "$ALIAS" "ubuntu@${IP}"
aws ec2 terminate-instances --instance-ids "$INSTANCE_ID" --region "$AWS_REGION"
```

**Run the full example:**
```bash
export AWS_REGION=us-east-1
export AWS_KEY_NAME=my-key
export AWS_SECURITY_GROUP=sg-xxxxx
./examples/aws.sh
```

### Local/Localhost Example

Simple example for using sessh with a local machine or VM:

```bash
#!/bin/bash
set -euo pipefail

HOST="${1:-localhost}"
USER="${USER:-$(whoami)}"
ALIAS="local-test"

cleanup() {
  sessh close "$ALIAS" "${USER}@${HOST}" 2>/dev/null || true
}
trap cleanup EXIT

# Open session
sessh open "$ALIAS" "${USER}@${HOST}"

# Run commands (state persists between commands)
sessh run "$ALIAS" "${USER}@${HOST}" -- "echo 'Hello from sessh!'"
sessh run "$ALIAS" "${USER}@${HOST}" -- "pwd"
sessh run "$ALIAS" "${USER}@${HOST}" -- "cd /tmp && pwd && echo 'State persisted!'"

# Get logs
sessh logs "$ALIAS" "${USER}@${HOST}" 50

# Check status
sessh status "$ALIAS" "${USER}@${HOST}"
```

**Run the full example:**
```bash
./examples/local.sh localhost
```

### Other Examples

Full examples are available for all major cloud providers:

- **Docker**: [`examples/docker.sh`](examples/docker.sh) - Use sessh with a Docker container
- **Google Cloud Platform**: [`examples/gcp.sh`](examples/gcp.sh) - Launch GCP instance, use sessh, terminate
- **Azure**: [`examples/azure.sh`](examples/azure.sh) - Launch Azure VM, use sessh, terminate
- **DigitalOcean**: [`examples/digitalocean.sh`](examples/digitalocean.sh) - Launch droplet, use sessh, terminate
- **Docker Compose**: [`examples/docker-compose.sh`](examples/docker-compose.sh) - Use sessh with Docker Compose services

All examples follow the same pattern:
1. Launch infrastructure (instance/container)
2. Wait for SSH to be ready
3. Open sessh session
4. Run commands (state persists between commands)
5. Fetch logs
6. Clean up resources

### JSON Mode for Automation

```bash
# Enable JSON output
export SESSH_JSON=1

# Parse responses
response=$(sessh open agent ubuntu@host)
alias=$(echo "$response" | jq -r '.alias')
status=$(sessh status agent ubuntu@host)
master=$(echo "$status" | jq -r '.master')
session=$(echo "$status" | jq -r '.session')
```

## Troubleshooting

**"tmux: command not found"**
- Install tmux on the remote host: `apt-get install tmux` or `brew install tmux`
- Or use `apt-get install tmux` in a one-time SSH session before using sessh

**"ControlMaster connection failed"**
- Check SSH key permissions: `chmod 600 ~/.ssh/id_ed25519`
- Verify network connectivity: `ssh -v ubuntu@host` (check for connection issues)
- Check firewall rules (SSH port 22 must be open)
- Ensure SSH server supports ControlMaster (modern OpenSSH)

**"autossh not found"**
- Install autossh: `apt-get install autossh` or `brew install autossh`
- Or use `SESSH_SSH=ssh` (default, no auto-reconnection)

**JSON parsing errors**
- Ensure `SESSH_JSON=1` is set
- Check that `jq` or Python 3 is available for JSON parsing
- Verify sessh output is actually JSON: `SESSH_JSON=1 sessh open test ubuntu@host`

**"Permission denied (publickey)"**
- Ensure your public key is in `~/.ssh/authorized_keys` on remote host
- Check SSH key path: `SESSH_IDENTITY=~/.ssh/id_ed25519 sessh open ...`
- Verify key permissions: `chmod 600 ~/.ssh/id_ed25519`

**Commands not persisting state**
- Verify tmux session exists: `sessh status alias host`
- Check if commands are running: `sessh logs alias host 50`
- Ensure you're using the same alias and host for all commands

**Control socket errors**
- Check socket directory permissions: `ls -la /run/user/$UID/`
- Set custom directory: `SESSH_CTRL_DIR=/tmp sessh open ...`
- Clean up old sockets: `rm -f /run/user/$UID/sessh_*` (if stuck)

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for development guidelines and philosophy.

## License

MIT License - see LICENSE file for details.

