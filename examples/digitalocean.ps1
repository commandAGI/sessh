# Example: Using sessh with DigitalOcean Droplets (PowerShell version)
# This demonstrates launching a DigitalOcean droplet, using sessh to train a model, and terminating it

$ErrorActionPreference = "Stop"

# Configuration
$DO_TOKEN = if ($env:DO_TOKEN) { $env:DO_TOKEN } else { "" }
$DO_REGION = if ($env:DO_REGION) { $env:DO_REGION } else { "nyc1" }
$DO_SIZE = if ($env:DO_SIZE) { $env:DO_SIZE } else { "s-1vcpu-1gb" }
$DO_IMAGE = if ($env:DO_IMAGE) { $env:DO_IMAGE } else { "ubuntu-22-04-x64" }
$DROPLET_NAME = "sessh-example-$(Get-Date -Format 'yyyyMMddHHmmss')"
$ALIAS = "do-agent"
$SESSH_BIN = if ($env:SESSH_BIN) { $env:SESSH_BIN } else { 
    $scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent (Get-Item $PSCommandPath).FullName }
    $parentDir = Split-Path -Parent $scriptDir
    $sesshPath = Join-Path $parentDir "sessh.ps1"
    if (Test-Path $sesshPath) {
        $sesshPath
    } else {
        "sessh.ps1"
    }
}

# Check prerequisites
if (-not (Get-Command doctl -ErrorAction SilentlyContinue)) {
    Write-Error "Error: doctl CLI is required but not installed."
    exit 1
}

if ([string]::IsNullOrEmpty($DO_TOKEN)) {
    Write-Error "Error: DO_TOKEN environment variable must be set with your DigitalOcean API token."
    Write-Host "Get one at: https://cloud.digitalocean.com/account/api/tokens"
    exit 1
}

# Authenticate doctl
doctl auth init --access-token $DO_TOKEN 2>$null | Out-Null

# Generate SSH key if needed
$SSH_KEY_PATH = "$env:USERPROFILE\.ssh\id_ed25519"
if (-not (Test-Path $SSH_KEY_PATH)) {
    Write-Host "Generating SSH key..."
    $sshDir = Split-Path $SSH_KEY_PATH
    if (-not (Test-Path $sshDir)) {
        New-Item -ItemType Directory -Path $sshDir -Force | Out-Null
    }
    ssh-keygen.exe -t ed25519 -f $SSH_KEY_PATH -N '""' -q
}

# Add SSH key to DigitalOcean if not already present
$SSH_KEY_NAME = "sessh-key"
$pubKeyContent = Get-Content "$SSH_KEY_PATH.pub" -Raw
$fingerprint = ssh-keygen.exe -l -f "$SSH_KEY_PATH.pub" -E md5 | ForEach-Object { if ($_ -match 'MD5:([^\s]+)') { $matches[1] } }

$existingKeys = doctl compute ssh-key list --format ID,Fingerprint --no-header 2>$null
$keyExists = $existingKeys | Select-String -Pattern $fingerprint

if (-not $keyExists) {
    Write-Host "Adding SSH key to DigitalOcean..."
    $pubKeyFile = "$env:TEMP\sessh-pubkey-$(Get-Random).txt"
    $pubKeyContent | Set-Content -Path $pubKeyFile
    doctl compute ssh-key create $SSH_KEY_NAME --public-key-file $pubKeyFile 2>$null | Out-Null
    Remove-Item $pubKeyFile -ErrorAction SilentlyContinue
}

$DROPLET_ID = ""
$IP = ""

function Cleanup {
    Write-Host "Cleaning up..."
    if ($ALIAS -and $IP) {
        & $SESSH_BIN close $ALIAS "root@${IP}" 2>$null | Out-Null
    }
    if ($DROPLET_ID) {
        Write-Host "Deleting DigitalOcean droplet: $DROPLET_ID"
        doctl compute droplet delete $DROPLET_ID --force 2>$null | Out-Null
    }
}

try {
    Write-Host "=== DigitalOcean Droplet Sessh Example ==="
    Write-Host "Region: $DO_REGION"
    Write-Host "Size: $DO_SIZE"
    Write-Host "Image: $DO_IMAGE"
    Write-Host ""

    # Launch droplet
    Write-Host "Creating DigitalOcean droplet..."
    $dropletOutput = doctl compute droplet create $DROPLET_NAME `
        --region $DO_REGION `
        --size $DO_SIZE `
        --image $DO_IMAGE `
        --ssh-keys $fingerprint `
        --format ID,PublicIPv4 `
        --no-header

    $DROPLET_ID = ($dropletOutput -split '\s+')[0]

    if ([string]::IsNullOrEmpty($DROPLET_ID)) {
        Write-Error "Error: Failed to create droplet."
        exit 1
    }

    Write-Host "Droplet ID: $DROPLET_ID"

    # Wait for droplet to be active and get IP
    Write-Host "Waiting for droplet to be active..."
    $maxAttempts = 60
    $attempt = 0
    while ($attempt -lt $maxAttempts) {
        $dropletInfo = doctl compute droplet get $DROPLET_ID --format ID,Status,PublicIPv4 --no-header 2>$null

        if ($dropletInfo) {
            $fields = $dropletInfo -split '\s+'
            $status = $fields[1]
            $ipRaw = $fields[2]

            if ($status -eq "active" -and $ipRaw -and $ipRaw -ne "none") {
                $IP = $ipRaw
                break
            }
        }
        Start-Sleep -Seconds 5
        $attempt++
    }

    if ([string]::IsNullOrEmpty($IP) -or $IP -eq "none") {
        Write-Error "Error: Failed to get droplet IP address."
        exit 1
    }

    Write-Host "Droplet IP: $IP"

    # Wait for SSH to be ready
    Write-Host "Waiting for SSH to be ready..."
    $maxAttempts = 60
    $attempt = 0
    while ($attempt -lt $maxAttempts) {
        $sshTest = ssh.exe -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new -i $SSH_KEY_PATH "root@${IP}" "echo ready" 2>$null
        if ($LASTEXITCODE -eq 0) {
            break
        }
        Start-Sleep -Seconds 5
        $attempt++
    }

    # Open session
    Write-Host "Opening sessh session..."
    $env:SESSH_IDENTITY = $SSH_KEY_PATH
    & $SESSH_BIN open $ALIAS "root@${IP}"

    # Install dependencies and run workload
    Write-Host "Installing dependencies..."
    & $SESSH_BIN run $ALIAS "root@${IP}" -- "apt-get update -qq"
    & $SESSH_BIN run $ALIAS "root@${IP}" -- "apt-get install -y -qq python3-pip tmux"

    Write-Host "Running workload..."
    & $SESSH_BIN run $ALIAS "root@${IP}" -- "python3 -c `"import sys; print(f'Python version: {sys.version}')`""
    & $SESSH_BIN run $ALIAS "root@${IP}" -- "cd /tmp && pwd && echo 'Working directory: $(pwd)' && echo 'State persisted across commands!'"

    # Get logs
    Write-Host ""
    Write-Host "=== Session Logs ==="
    & $SESSH_BIN logs $ALIAS "root@${IP}" 100

    # Check status
    Write-Host ""
    Write-Host "=== Session Status ==="
    & $SESSH_BIN status $ALIAS "root@${IP}"

    Write-Host ""
    Write-Host "Example completed successfully!"
    Write-Host "Droplet $DROPLET_ID will be deleted on exit."
} finally {
    Cleanup
}

