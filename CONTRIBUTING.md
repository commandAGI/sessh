# Contributing to Sessh

Thank you for your interest in contributing to sessh! This document outlines our philosophy, development process, and how to contribute effectively.

## Philosophy

Sessh exists to solve a specific problem: **AI agents like Cursor can only run one-off terminal commands, but they need to operate persistent interactive shells on remote hosts**.

### Core Principles

1. **Fail Loudly, Not Gracefully**: We don't add fallbacks or backwards compatibility unless explicitly necessary. If something breaks, we want it to break clearly and loudly so issues are immediately apparent.

2. **Single-Command Interface**: Every operation must be a single command that terminates immediately. The CLI returns immediately; the persistent shell lives on in tmux on the remote host.

3. **Real Implementations**: We use real POSIX tools (SSH ControlMaster, tmux) rather than building abstractions. When OpenSSH and tmux solve the problem, we use them.

4. **Autonomous by Default**: The entire goal is enabling autonomous workflows. Launch infrastructure → SSH → train models → terminate, all without human intervention.

5. **Security First**: Hardened SSH defaults (modern KEX, ciphers, MACs). No password authentication. Strict host key checking. Key-only auth.

## Architecture

Sessh works by combining two technologies:

1. **SSH ControlMaster/ControlPersist**: Opens a persistent master connection that multiplexes multiple sessions
2. **Remote tmux**: Maintains a truly interactive shell on the remote host with state (cwd, environment, etc.)

When you run `sessh open agent ubuntu@host`, it:
- Opens a ControlMaster connection (persists for 8h by default)
- Creates a detached tmux session named "agent" on the remote
- Returns immediately

When you run `sessh run agent ubuntu@host -- "command"`, it:
- Reuses the existing ControlMaster connection (instant)
- Sends the command via `tmux send-keys` into the persistent session
- Returns immediately

This enables AI agents to chain commands like:
```bash
sessh open agent ubuntu@$ip
sessh run agent ubuntu@$ip -- "conda activate env && python train.py"
sessh logs agent ubuntu@$ip 400
```

## Development Setup

### Prerequisites

- Bash 4.0+ (with associative arrays support)
- OpenSSH client with ControlMaster support
- `tmux` (for testing on remote hosts)
- `jq` (optional, for JSON parsing)
- `autossh` (optional, for auto-reconnection)

### Testing

We don't have automated tests yet (we're open to contributions here!). Manual testing workflow:

1. Set up a test SSH host (local VM, EC2 instance, etc.)
2. Ensure tmux is installed on the remote
3. Test each command manually:
   ```bash
   ./sessh open test ubuntu@test-host
   ./sessh run test ubuntu@test-host -- "echo hello"
   ./sessh logs test ubuntu@test-host
   ./sessh status test ubuntu@test-host
   ./sessh close test ubuntu@test-host
   ```

4. Test with JSON output:
   ```bash
   SESSH_JSON=1 ./sessh open test ubuntu@test-host | jq
   ```

5. Test with autossh:
   ```bash
   SESSH_SSH=autossh AUTOSSH_GATETIME=0 ./sessh open test ubuntu@test-host
   ```

## Code Style

- Use `set -euo pipefail` for strict error handling
- Prefer `printf` over `echo` for portability
- Quote all variables to prevent word splitting
- Use `local` for function-scoped variables
- Comment complex logic, especially SSH option handling

## Submitting Changes

1. **Fork the repository** (if you don't have write access)

2. **Create a feature branch**:
   ```bash
   git checkout -b feature/your-feature-name
   ```

3. **Make your changes**:
   - Keep changes focused and atomic
   - Update documentation if needed
   - Test thoroughly on your own infrastructure

4. **Commit your changes**:
   ```bash
   git commit -m "feat: add support for X"
   ```
   Use conventional commit prefixes:
   - `feat:` - New feature
   - `fix:` - Bug fix
   - `docs:` - Documentation only
   - `refactor:` - Code refactoring
   - `test:` - Adding tests

5. **Push and open a PR**:
   ```bash
   git push origin feature/your-feature-name
   ```

## Pull Request Process

1. **Describe the problem**: What issue does this solve? Why is this needed?

2. **Describe the solution**: How does your change solve the problem?

3. **Show it works**: Include examples of the new functionality in action

4. **Keep it focused**: One feature or fix per PR

5. **Update docs**: If you're adding features, update the README

## What We're Looking For

### High Priority

- **Reliability improvements**: Better error handling, edge case coverage
- **Documentation**: More examples, troubleshooting guides, architecture docs
- **Testing**: Automated test suite, integration tests
- **Security**: Security audits, hardening improvements

### Nice to Have

- **Performance**: Faster connection establishment, better multiplexing
- **Features**: New commands that fit the single-command philosophy
- **Platform support**: Better Windows/WSL support, macOS optimizations

### Not Looking For

- **Backwards compatibility layers**: If we break something, we'll document it and move on
- **Abstractions over SSH/tmux**: We use these tools directly for a reason
- **Interactive CLI modes**: The whole point is non-interactive single commands

## Questions?

Open an issue with the `question` label. We're happy to discuss architecture, design decisions, or help you get started.

## Code of Conduct

Be respectful, assume good intent, and focus on building something useful. We're here to enable autonomous AI workflows, not to argue about tabs vs spaces.

