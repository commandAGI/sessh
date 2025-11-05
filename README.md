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

### Lambda Labs GPU Training

```bash
#!/bin/bash
set -euo pipefail

export LAMBDA_API_KEY="sk_live_..."
export LAMBDA_REGION="us-west-1"
export LAMBDA_INSTANCE_TYPE="gpu_1x_h100_sxm5"

# Launch instance
response=$(curl -su "$LAMBDA_API_KEY:" \
  -H "content-type: application/json" \
  -X POST https://cloud.lambdalabs.com/api/v1/instance-operations/launch \
  -d "{\"region_name\":\"$LAMBDA_REGION\",\"instance_type_name\":\"$LAMBDA_INSTANCE_TYPE\",\"ssh_key_names\":[\"laptop-ed25519\"],\"quantity\":1}")

iid=$(echo "$response" | jq -r '.data.instance_ids[0]')

# Wait for IP
until ip=$(curl -su "$LAMBDA_API_KEY:" \
  https://cloud.lambdalabs.com/api/v1/instances | \
  jq -r ".data[] | select(.id==\"$iid\") | .ip") && [[ "$ip" != "null" ]]; do
  sleep 5
done

echo "Instance ready at $ip"

# Train model
sessh open agent "ubuntu@$ip"
sessh run agent "ubuntu@$ip" -- "pip install torch torchvision"
sessh run agent "ubuntu@$ip" -- "python train.py"
sessh logs agent "ubuntu@$ip" 400

# Terminate
curl -su "$LAMBDA_API_KEY:" \
  -H "content-type: application/json" \
  -X POST https://cloud.lambdalabs.com/api/v1/instance-operations/terminate \
  -d "{\"instance_ids\": [\"$iid\"]}"
```

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

