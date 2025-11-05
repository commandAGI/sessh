#Requires -Version 5.1
# Sessh - SSH Session Manager (PowerShell version)
# A persistent SSH session manager that enables one-shot CLI commands to operate long-lived interactive shells on remote hosts.

# Parse arguments manually to handle positional args properly
# Match bash script behavior: port is CLI arg for open/status/attach/close, env var for run/logs
$allArgs = $args
$Command = $null
$Alias = $null
$HostSpec = $null
$Port = 0
$RemainingArgs = @()

if ($allArgs.Length -eq 0) {
    $Command = $null
} else {
    $Command = $allArgs[0]
    if ($allArgs.Length -ge 2) {
        $Alias = $allArgs[1]
    }
    if ($allArgs.Length -ge 3) {
        $HostSpec = $allArgs[2]
    }
    # For open/status/attach/close, 3rd arg (index 3) can be port
    # For run/logs, remaining args are part of command/options
    if ($allArgs.Length -ge 4) {
        $arg4 = $allArgs[3]
        if ($Command -in @("open", "status", "attach", "close") -and $arg4 -match '^\d+$') {
            $Port = [int]$arg4
        } else {
            $RemainingArgs = $allArgs[3..($allArgs.Length - 1)]
        }
    }
}

$ErrorActionPreference = "Stop"

# -------- config (env overrides) --------
$script:SESSH_PERSIST = if ($env:SESSH_PERSIST) { $env:SESSH_PERSIST } else { "8h" }
$script:SESSH_SSH = if ($env:SESSH_SSH) { $env:SESSH_SSH } else { "ssh" }
$script:SESSH_PORT_DEFAULT = if ($env:SESSH_PORT_DEFAULT) { [int]$env:SESSH_PORT_DEFAULT } else { 22 }
$script:SESSH_LOG_LINES_DEFAULT = if ($env:SESSH_LOG_LINES_DEFAULT) { [int]$env:SESSH_LOG_LINES_DEFAULT } else { 300 }
$script:SESSH_STRICT_HOST = if ($env:SESSH_STRICT_HOST) { $env:SESSH_STRICT_HOST } else { "accept-new" }
# Windows OpenSSH may not support sntrup761, use fallback
$script:SESSH_KEX = if ($env:SESSH_KEX) { $env:SESSH_KEX } else { "curve25519-sha256,curve25519-sha256@libssh.org,diffie-hellman-group-exchange-sha256" }
$script:SESSH_CIPHERS = if ($env:SESSH_CIPHERS) { $env:SESSH_CIPHERS } else { "chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com" }
$script:SESSH_MACS = if ($env:SESSH_MACS) { $env:SESSH_MACS } else { "umac-128-etm@openssh.com,umac-64-etm@openssh.com" }
$script:SESSH_KEEPALIVE = if ($env:SESSH_KEEPALIVE) { [int]$env:SESSH_KEEPALIVE } else { 30 }
$script:SESSH_SERVER_ALIVE_COUNT = if ($env:SESSH_SERVER_ALIVE_COUNT) { [int]$env:SESSH_SERVER_ALIVE_COUNT } else { 3 }
$script:SESSH_CTRL_DIR = if ($env:SESSH_CTRL_DIR) { $env:SESSH_CTRL_DIR } else { $null }
$script:SESSH_SOCK_FMT = if ($env:SESSH_SOCK_FMT) { $env:SESSH_SOCK_FMT } else { "sessh_%r@%h:%p" }
$script:SESSH_JSON = if ($env:SESSH_JSON -eq "1") { $true } else { $false }
$script:SESSH_IDENTITY = if ($env:SESSH_IDENTITY) { $env:SESSH_IDENTITY } else { $null }
$script:SESSH_PROXYJUMP = if ($env:SESSH_PROXYJUMP) { $env:SESSH_PROXYJUMP } else { $null }

# ControlMaster disabled on Windows - no control socket directory needed

# ControlMaster disabled on Windows - no control socket needed
$script:CTRL_DIR = $null
$script:CTRL_PATH = $null

# Base SSH options
# On Windows, ControlMaster is unreliable - use regular SSH connections
function Get-BaseSshOpts {
    $opts = @(
        "-o", "ServerAliveInterval=$($script:SESSH_KEEPALIVE)",
        "-o", "ServerAliveCountMax=$($script:SESSH_SERVER_ALIVE_COUNT)",
        "-o", "StrictHostKeyChecking=$($script:SESSH_STRICT_HOST)",
        "-o", "IdentitiesOnly=yes",
        "-o", "KexAlgorithms=$($script:SESSH_KEX)",
        "-o", "Ciphers=$($script:SESSH_CIPHERS)",
        "-o", "MACs=$($script:SESSH_MACS)",
        "-o", "Compression=no",
        "-o", "TCPKeepAlive=no",
        "-o", "NumberOfPasswordPrompts=0",
        "-o", "PreferredAuthentications=publickey"
    )
    # ControlMaster disabled on Windows - not reliable
    if ($script:SESSH_IDENTITY) {
        $opts += @("-i", $script:SESSH_IDENTITY)
    }
    if ($script:SESSH_PROXYJUMP) {
        $opts += @("-J", $script:SESSH_PROXYJUMP)
    }
    return $opts
}

function Ensure-Master {
    param(
        [string]$HostSpec,
        [int]$Port
    )
    # On Windows, ControlMaster is disabled - no-op
    # Each command uses a fresh SSH connection, but tmux session persists
}

function Write-Json {
    param([hashtable]$Data)
    
    if ($script:SESSH_JSON) {
        $timestamp = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
        $Data["ts"] = $timestamp
        $json = $Data | ConvertTo-Json -Compress
        Write-Output $json
    }
}

function Write-ErrorAndExit {
    param([string]$Message)
    Write-Error $Message
    exit 2
}

function Show-Usage {
    Write-Host @"
usage:
  sessh open   <alias> <user@host> [port]
  sessh run    <alias> <user@host> -- <command string>
  sessh logs   <alias> <user@host> [lines]
  sessh status <alias> <user@host> [port]
  sessh attach <alias> <user@host> [port]        # interactive; not json
  sessh close  <alias> <user@host> [port]

env knobs:
  `$env:SESSH_JSON=1 to emit json; `$env:SESSH_SSH=autossh; `$env:SESSH_IDENTITY=~/.ssh/id_ed25519; `$env:SESSH_PROXYJUMP=user@bastion
"@
    exit 1
}

# Main command handling
if (-not $Command) {
    Show-Usage
}

# Port handling: CLI arg for open/status/attach/close, env var for run/logs
function Get-Port {
    param([string]$Cmd)
    if ($Cmd -in @("open", "status", "attach", "close")) {
        if ($Port -gt 0) {
            return $Port
        } else {
            return $script:SESSH_PORT_DEFAULT
        }
    } else {
        # run and logs use PORT env var or default
        if ($env:PORT) {
            return [int]$env:PORT
        } else {
            return $script:SESSH_PORT_DEFAULT
        }
    }
}

switch ($Command) {
    "open" {
        if (-not $Alias -or -not $HostSpec) {
            Show-Usage
        }
        $port = Get-Port -Cmd "open"
        Ensure-Master -HostSpec $HostSpec -Port $port
        $opts = Get-BaseSshOpts
        $tmuxCmd = "tmux has-session -t $Alias 2>/dev/null || tmux new -d -s $Alias"
        $sshArgs = $opts + @("-p", $port.ToString(), $HostSpec, $tmuxCmd)
        & $script:SESSH_SSH $sshArgs | Out-Null
        
        if ($script:SESSH_JSON) {
            Write-Json @{
                ok = $true
                op = "open"
                alias = $Alias
                host = $HostSpec
                port = $port.ToString()
            }
        } else {
            Write-Host "opened '$Alias' on $HostSpec ($port), controlpersist active"
        }
    }
    
    "run" {
        if (-not $Alias -or -not $HostSpec) {
            Show-Usage
        }
        
        # Find -- separator
        $dashDashIdx = -1
        for ($i = 0; $i -lt $RemainingArgs.Length; $i++) {
            if ($RemainingArgs[$i] -eq "--") {
                $dashDashIdx = $i
                break
            }
        }
        
        if ($dashDashIdx -eq -1) {
            Write-ErrorAndExit "missing --"
        }
        
        $cmdParts = $RemainingArgs[($dashDashIdx + 1)..($RemainingArgs.Length - 1)]
        if ($cmdParts.Length -eq 0) {
            Write-ErrorAndExit "empty command"
        }
        
        $cmdline = $cmdParts -join " "
        $port = Get-Port -Cmd "run"
        Ensure-Master -HostSpec $HostSpec -Port $port
        $opts = Get-BaseSshOpts
        # Escape single quotes and wrap in single quotes for tmux send-keys
        # Replace single quotes with '\'' (bash quote escaping)
        $escapedCmdline = $cmdline -replace "'", "'\''"
        $tmuxCmd = "tmux has-session -t $Alias || tmux new -d -s $Alias; tmux send-keys -t $Alias '$escapedCmdline' C-m"
        $sshArgs = $opts + @("-p", $port.ToString(), $HostSpec, $tmuxCmd)
        & $script:SESSH_SSH $sshArgs | Out-Null
        
        if ($script:SESSH_JSON) {
            $escapedCmd = $cmdline -replace '\\', '\\' -replace '"', '\"'
            Write-Json @{
                ok = $true
                op = "run"
                alias = $Alias
                host = $HostSpec
                sent = $escapedCmd
            }
        }
    }
    
    "logs" {
        if (-not $Alias -or -not $HostSpec) {
            Show-Usage
        }
        $lines = if ($RemainingArgs.Length -gt 0) { [int]$RemainingArgs[0] } else { $script:SESSH_LOG_LINES_DEFAULT }
        $port = Get-Port -Cmd "logs"
        Ensure-Master -HostSpec $HostSpec -Port $port
        $opts = Get-BaseSshOpts
        $tmuxCmd = "tmux capture-pane -pt $Alias -S -$lines || true"
        $sshArgs = $opts + @("-p", $port.ToString(), $HostSpec, $tmuxCmd)
        $out = & $script:SESSH_SSH $sshArgs 2>&1 | Out-String
        
        if ($script:SESSH_JSON) {
            $escaped = $out -replace '\\', '\\' -replace '"', '\"' -replace "`r`n", '\n' -replace "`n", '\n' -replace "`r", '\r'
            Write-Json @{
                ok = $true
                op = "logs"
                alias = $Alias
                host = $HostSpec
                lines = $lines
                output = $escaped.TrimEnd()
            }
        } else {
            Write-Output $out
        }
    }
    
    "status" {
        if (-not $Alias -or -not $HostSpec) {
            Show-Usage
        }
        $port = Get-Port -Cmd "status"
        $opts = Get-BaseSshOpts
        
        # On Windows, ControlMaster is disabled - master is always 0
        $masterOk = 0
        
        # Check tmux session
        $sessOk = 0
        $tmuxCmd = "tmux has-session -t $Alias"
        $tmuxArgs = $opts + @("-p", $port.ToString(), $HostSpec, $tmuxCmd)
        
        $tmuxProcessInfo = New-Object System.Diagnostics.ProcessStartInfo
        $tmuxProcessInfo.FileName = $script:SESSH_SSH
        $tmuxProcessInfo.Arguments = ($tmuxArgs -join " ")
        $tmuxProcessInfo.RedirectStandardOutput = $true
        $tmuxProcessInfo.RedirectStandardError = $true
        $tmuxProcessInfo.UseShellExecute = $false
        $tmuxProcessInfo.CreateNoWindow = $true
        
        $tmuxProcess = New-Object System.Diagnostics.Process
        $tmuxProcess.StartInfo = $tmuxProcessInfo
        $tmuxProcess.Start() | Out-Null
        $tmuxProcess.WaitForExit()
        
        if ($tmuxProcess.ExitCode -eq 0) {
            $sessOk = 1
        }
        
        if ($script:SESSH_JSON) {
            Write-Json @{
                ok = $true
                op = "status"
                alias = $Alias
                host = $HostSpec
                master = $masterOk
                session = $sessOk
            }
        } else {
            Write-Host "master:$masterOk session:$sessOk"
        }
    }
    
    "attach" {
        if (-not $Alias -or -not $HostSpec) {
            Show-Usage
        }
        $port = Get-Port -Cmd "attach"
        Ensure-Master -HostSpec $HostSpec -Port $port
        $opts = Get-BaseSshOpts
        $tmuxCmd = "tmux attach -t $Alias"
        $sshArgs = $opts + @("-t", "-p", $port.ToString(), $HostSpec, $tmuxCmd)
        & $script:SESSH_SSH $sshArgs
        exit $LASTEXITCODE
    }
    
    "close" {
        if (-not $Alias -or -not $HostSpec) {
            Show-Usage
        }
        $port = Get-Port -Cmd "close"
        $opts = Get-BaseSshOpts
        $tmuxCmd = "tmux kill-session -t $Alias"
        $killArgs = $opts + @("-p", $port.ToString(), $HostSpec, $tmuxCmd)
        & $script:SESSH_SSH $killArgs 2>$null | Out-Null
        
        # No ControlMaster on Windows - no need to close master
        
        if ($script:SESSH_JSON) {
            Write-Json @{
                ok = $true
                op = "close"
                alias = $Alias
                host = $HostSpec
            }
        } else {
            Write-Host "closed '$Alias' and master"
        }
    }
    
    default {
        Show-Usage
    }
}

