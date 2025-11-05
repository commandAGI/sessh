# Sessh Architecture

This document explains the design philosophy and technical architecture of sessh.

## Philosophy

Sessh exists to solve one specific problem: **AI agents like Cursor can only run single commands that terminate immediately, but they need to operate persistent interactive shells on remote hosts**.

### Core Principles

1. **Fail Loudly, Not Gracefully**: We don't add fallbacks or backwards compatibility unless explicitly necessary. If something breaks, we want it to break clearly.

2. **Single-Command Interface**: Every operation must be a single command that terminates immediately. The CLI returns immediately; the persistent shell lives on in tmux on the remote host.

3. **Real Implementations**: We use real tools (SSH ControlMaster, tmux) rather than building abstractions. When OpenSSH and tmux solve the problem, we use them. On Windows, we use PowerShell's native capabilities to interface with OpenSSH.

4. **Autonomous by Default**: The entire goal is enabling autonomous workflows. Launch infrastructure → SSH → train models → terminate, all without human intervention.

5. **Security First**: Hardened SSH defaults (modern KEX, ciphers, MACs). No password authentication. Strict host key checking.

## Technical Architecture

### The Two-Layer Solution

Sessh combines two independent technologies:

1. **SSH ControlMaster/ControlPersist** - Persistent TCP connections
2. **Remote tmux** - Persistent interactive shells

This separation is intentional: ControlMaster handles connection persistence, tmux handles shell state persistence.

### Layer 1: SSH ControlMaster

**Problem**: Opening a new SSH connection for each command is slow (TCP handshake, SSH handshake, key exchange, authentication).

**Solution**: SSH ControlMaster/ControlPersist maintains a persistent "master" connection that multiplexes multiple sessions.

#### How It Works

When you run `sessh open agent ubuntu@host`:

```bash
# Opens a master connection (background)
ssh -MNf \
  -o ControlMaster=yes \
  -o ControlPersist=8h \
  -o ControlPath=/run/user/$UID/sessh_%r@%h:%p \
  -p 22 ubuntu@host
```

- `-M`: Put in master mode
- `-N`: Don't execute remote command (just hold connection)
- `-f`: Background the process
- `ControlPersist=8h`: Keep connection alive for 8 hours
- `ControlPath`: Unix socket for multiplexing

Subsequent commands reuse this connection:

```bash
# Reuses master connection (instant, no handshake)
ssh -o ControlPath=... -O check ubuntu@host  # Check if master exists
ssh -o ControlPath=... ubuntu@host "command"  # Execute via master
```

#### Control Socket Location

We prioritize fast storage for speed:

**Linux/macOS (Bash script):**
1. `/run/user/$UID` (systemd user runtime, ramfs)
2. `$XDG_RUNTIME_DIR` (XDG standard, usually ramfs)
3. `/tmp` (fallback, disk-backed)

**Windows (PowerShell script):**
1. `$env:LOCALAPPDATA\sessh` (user-specific application data, fast SSD)
2. `$env:TEMP` (system temp directory, fallback)

Note: SSH on Windows requires forward slashes in ControlPath even for Windows paths, so we convert backslashes to forward slashes.

Socket format: `sessh_%r@%h:%p` (user@host:port)

#### Connection Management

- **Master connection**: Persists for 8 hours (configurable via `SESSH_PERSIST`)
- **Keepalives**: `ServerAliveInterval=30`, `ServerAliveCountMax=3`
- **Auto-reconnection**: Optional `autossh` support via `SESSH_SSH=autossh`

### Layer 2: Remote Tmux

**Problem**: Even with ControlMaster, each command runs in a new shell with no state (no cwd, no environment, no processes).

**Solution**: Remote tmux maintains a persistent interactive shell session.

#### How It Works

When you run `sessh open agent ubuntu@host`:

```bash
# On remote host, create detached tmux session
tmux new -d -s agent
```

This creates a detached tmux session named "agent" with a real interactive shell.

When you run `sessh run agent ubuntu@host -- "command"`:

```bash
# Send command to tmux session (simulates typing + Enter)
tmux send-keys -t agent "command" C-m
```

The command runs in the persistent shell, maintaining:
- Current working directory
- Environment variables
- Active processes (if any)
- Shell history

When you run `sessh logs agent ubuntu@host`:

```bash
# Capture last N lines from tmux pane
tmux capture-pane -pt agent -S -300
```

#### Why Tmux (Not screen, not bare shells)?

- **tmux** is widely available, modern, and well-maintained
- `tmux send-keys` reliably simulates interactive input
- `tmux capture-pane` reliably captures output
- `tmux attach` allows human inspection when needed
- Detached sessions persist across SSH disconnections

### Combined Flow

```
┌─────────────┐
│ AI Agent    │
│ (Cursor)    │
└──────┬──────┘
       │
       │ sessh open agent ubuntu@host
       │ (returns immediately)
       ▼
┌─────────────┐
│ sessh CLI   │
└──────┬──────┘
       │
       │ 1. Opens ControlMaster (background)
       │ 2. Creates tmux session (remote)
       │ 3. Returns immediately
       ▼
┌─────────────────────────────────────────┐
│ Remote Host                             │
│                                         │
│ ┌─────────────────────────────────────┐ │
│ │ SSH ControlMaster (persistent TCP)  │ │
│ └─────────────────────────────────────┘ │
│                  │                        │
│                  ▼                        │
│ ┌─────────────────────────────────────┐ │
│ │ tmux session "agent" (detached)     │ │
│ │ ┌─────────────────────────────────┐ │ │
│ │ │ Interactive shell (bash/zsh)    │ │ │
│ │ │ - cwd: /home/ubuntu             │ │ │
│ │ │ - env: PATH, HOME, etc.          │ │ │
│ │ │ - processes: (if any)            │ │ │
│ │ └─────────────────────────────────┘ │ │
│ └─────────────────────────────────────┘ │
└─────────────────────────────────────────┘

       │
       │ sessh run agent ubuntu@host -- "command"
       │ (returns immediately)
       ▼
┌─────────────┐
│ sessh CLI   │
└──────┬──────┘
       │
       │ 1. Reuses ControlMaster (instant)
       │ 2. tmux send-keys (sends command)
       │ 3. Returns immediately
       ▼
[Command runs in persistent tmux shell]
```

## Security Architecture

### SSH Hardening

We use modern, secure SSH defaults:

- **KEX**: `sntrup761x25519-sha512@openssh.com,curve25519-sha256`
- **Ciphers**: `chacha20-poly1305@openssh.com,aes256-gcm@openssh.com`
- **MACs**: `umac-128-etm@openssh.com,umac-64-etm@openssh.com`
- **No compression**: Reduces attack surface
- **No TCP keepalive**: Handled by ServerAliveInterval
- **Key-only auth**: `PreferredAuthentications=publickey`, `NumberOfPasswordPrompts=0`
- **Strict host keys**: `StrictHostKeyChecking=accept-new` (default)

### Control Socket Security

- **Linux/macOS**: Control sockets stored in user-owned directories (`/run/user/$UID`)
  - Unix socket permissions prevent other users from hijacking connections
- **Windows**: Control sockets stored in user-specific directory (`$env:LOCALAPPDATA\sessh`)
  - Windows file permissions prevent other users from accessing
- Each connection uses unique socket path (`%r@%h:%p`)

### Identity Isolation

- `IdentitiesOnly=yes`: Only use specified identity file
- Explicit identity via `SESSH_IDENTITY` environment variable
- No fallback to SSH agent unless explicitly configured

## Error Handling Philosophy

**Fail Loudly**: We don't silently fail or add fallbacks.

- If ControlMaster fails to open → exit with error
- If tmux command fails → exit with error
- If JSON parsing fails → exit with error

This makes debugging easier: if something breaks, you know immediately.

## Performance Considerations

### ControlMaster Reuse

- First connection: ~1-2 seconds (SSH handshake)
- Subsequent commands: ~10-50ms (socket multiplexing)

### Control Socket Performance

**Linux/macOS:**
- Disk-backed (`/tmp`): ~100-200ms per command
- Ramfs (`/run/user/$UID`): ~10-50ms per command

**Windows:**
- `LOCALAPPDATA` (typically SSD): ~20-50ms per command
- `TEMP` (disk-backed): ~50-100ms per command

### Tmux Overhead

- `tmux send-keys`: Negligible (~1-5ms)
- `tmux capture-pane`: Depends on pane size (~10-100ms for 300 lines)

## Limitations

1. **Requires tmux on remote**: Remote hosts must have tmux installed
2. **ControlMaster persistence**: Connections expire after 8h (configurable)
3. **No interactive stdin**: Can't send interactive input (use `sessh attach` for that)
4. **Command output delay**: Commands run asynchronously; use `logs` to check output
5. **Platform-specific considerations**:
   - **Control sockets**: Work best on Unix-like systems (Linux, macOS) with ramfs
   - **Windows**: Uses `LOCALAPPDATA` for control sockets (disk-backed, but fast on SSDs)
   - **autossh**: Not available on Windows PowerShell version (use standard `ssh` instead)

## Future Considerations

### Potential Enhancements

- **WebSocket gateway**: REST API for HTTP-based clients
- **Connection pooling**: Multiple master connections per host
- **Command queuing**: Queue commands if master connection is down
- **Output streaming**: Stream command output in real-time (harder with single-command interface)

### Not Planning

- **Backwards compatibility layers**: If we break something, we document it and move on
- **Abstractions over SSH/tmux**: We use these tools directly for a reason
- **Interactive CLI modes**: The whole point is non-interactive single commands
- **Password authentication**: Security risk, use keys

## Platform-Specific Implementation Notes

### PowerShell Implementation (Windows)

The PowerShell version (`sessh.ps1`) maintains feature parity with the bash version while adapting to Windows-specific requirements:

1. **Control Socket Paths**: Uses Windows paths (`$env:LOCALAPPDATA\sessh`) but converts to forward slashes for SSH compatibility
2. **Process Execution**: Uses PowerShell's `&` operator and `Start-Process` for background processes
3. **JSON Output**: Uses PowerShell's built-in `ConvertTo-Json` instead of external `jq`
4. **Environment Variables**: Uses `$env:VAR` syntax instead of `$VAR`
5. **Argument Parsing**: Manual argument parsing to handle positional parameters correctly
6. **Error Handling**: Uses PowerShell's `$ErrorActionPreference` and `try/catch` where appropriate

### Key Differences from Bash Version

- **autossh**: Not typically available on Windows, so PowerShell version uses standard `ssh` (autossh can be installed but isn't required)
- **Control Socket Creation**: Automatically creates the `sessh` directory in `LOCALAPPDATA` if it doesn't exist
- **Path Handling**: Converts Windows backslashes to forward slashes for SSH ControlPath (SSH on Windows requires forward slashes)

## Related Technologies

- **SSH ControlMaster**: [OpenSSH Multiplexing](https://en.wikibooks.org/wiki/OpenSSH/Cookbook/Multiplexing)
- **tmux**: [tmux Manual](https://man.openbsd.org/tmux)
- **autossh**: [autossh Manual](https://man.openbsd.org/autossh) (Linux/macOS only)

## References

- Original design discussion: See repository issues and PRs
- SSH ControlMaster documentation: `man ssh_config` (ControlMaster, ControlPersist, ControlPath)
- tmux documentation: `man tmux`

