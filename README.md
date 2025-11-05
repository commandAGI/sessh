# Sessh - SSH Session Manager

A persistent SSH session manager that enables one-shot CLI commands to operate long-lived interactive shells on remote hosts. Perfect for AI agents like Cursor that can only run single commands.

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

1. **ControlMaster**: Opens a persistent SSH master connection using ControlMaster/ControlPersist
2. **Remote Tmux**: Creates a detached tmux session on the remote host
3. **Command Execution**: Sends commands via `tmux send-keys` for true interactive execution
4. **State Persistence**: The tmux session maintains state (cwd, environment, etc.) between commands
5. **Log Capture**: Retrieves output via `tmux capture-pane`

## Use Cases

- **AI Agents**: Enable Cursor and other agents to operate remote SSH shells via single commands
- **CI/CD**: Long-running build/test jobs on remote infrastructure
- **Training Workflows**: Launch GPU instances, train models, terminate automatically
- **Development**: Persistent remote development environments

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

## Troubleshooting

**"tmux: command not found"**
- Install tmux on the remote host: `apt-get install tmux` or `brew install tmux`

**"ControlMaster connection failed"**
- Check SSH key permissions: `chmod 600 ~/.ssh/id_ed25519`
- Verify network connectivity
- Check firewall rules

**"autossh not found"**
- Install autossh or use `SESSH_SSH=ssh` (default)

**JSON parsing errors**
- Ensure `SESSH_JSON=1` is set
- Check that `jq` or Python 3 is available for JSON parsing

