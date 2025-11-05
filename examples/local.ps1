# Example: Using sessh with a localhost or local VM (PowerShell version)
# This demonstrates sessh usage on a local machine or VM accessible via SSH
# Usage: .\examples\local.ps1 [host]

param(
    [string]$TargetHost = "localhost"
)

$ErrorActionPreference = "Stop"

# Configuration
$User = $env:USERNAME
$Alias = "local-test"
$SesshBin = if ($env:SESSH_BIN) { $env:SESSH_BIN } else { 
    $scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent (Get-Item $PSCommandPath).FullName }
    $parentDir = Split-Path -Parent $scriptDir
    $sesshPath = Join-Path $parentDir "sessh.ps1"
    if (Test-Path $sesshPath) {
        $sesshPath
    } else {
        "sessh.ps1"  # Fallback to PATH
    }
}

function Cleanup {
    Write-Host "Cleaning up..."
    try {
        if ($Alias -and $TargetHost) {
            & $SesshBin close $Alias "${User}@${TargetHost}" 2>&1 | Out-Null
        }
    } catch {
        # Ignore cleanup errors
    }
}

# Setup cleanup trap
try {

Write-Host "=== Local Sessh Example (PowerShell) ==="
Write-Host "Host: ${User}@${TargetHost}"
Write-Host ""

# Ensure tmux is installed on remote (if not localhost)
# Note: This assumes a Linux remote host; adjust for Windows remotes
if ($TargetHost -ne "localhost" -and $TargetHost -ne "127.0.0.1") {
    Write-Host "Checking tmux on remote host..."
    $tmuxCheck = ssh "${User}@${TargetHost}" "command -v tmux >/dev/null 2>&1 || echo 'not-found'" 2>$null
    if ($tmuxCheck -eq "not-found") {
        Write-Host "Installing tmux on remote host..."
        ssh "${User}@${TargetHost}" "sudo apt-get update && sudo apt-get install -y tmux" 2>$null | Out-Null
    }
}

# Open session
Write-Host "Opening sessh session..."
& $SesshBin open $Alias "${User}@${TargetHost}"

# Run commands
Write-Host "Running commands..."
& $SesshBin run $Alias "${User}@${TargetHost}" -- "echo 'Hello from sessh!'"
& $SesshBin run $Alias "${User}@${TargetHost}" -- "pwd"
& $SesshBin run $Alias "${User}@${TargetHost}" -- "whoami"
& $SesshBin run $Alias "${User}@${TargetHost}" -- "cd /tmp && pwd && echo 'State persisted!'"

# Get logs
Write-Host ""
Write-Host "=== Session Logs ==="
& $SesshBin logs $Alias "${User}@${TargetHost}" 50

# Check status
Write-Host ""
Write-Host "=== Session Status ==="
& $SesshBin status $Alias "${User}@${TargetHost}"

Write-Host ""
Write-Host "Example completed successfully!"
} finally {
    Cleanup
}

