# Example: Using sessh with Docker Compose (PowerShell version)
# This demonstrates using sessh with services defined in docker-compose.yml

$ErrorActionPreference = "Stop"

# Configuration
$COMPOSE_FILE = if ($env:COMPOSE_FILE) { $env:COMPOSE_FILE } else { "docker-compose.yml" }
$SERVICE_NAME = if ($env:SERVICE_NAME) { $env:SERVICE_NAME } else { "test-service" }
$ALIAS = "compose-test"
# Use random port if not specified to avoid conflicts
$SSH_PORT = if ($env:SSH_PORT) { $env:SSH_PORT } else { 
    $randomPort = Get-Random -Minimum 2222 -Maximum 65535
    $SSH_PORT = $randomPort.ToString()
    Write-Host "Using random port: $SSH_PORT"
    $SSH_PORT
}
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

function Cleanup {
    Write-Host "Cleaning up..."
    try {
        if ($ALIAS) {
            & $SESSH_BIN close $ALIAS "root@localhost" $SSH_PORT 2>&1 | Out-Null
        }
    } catch {
        # Ignore cleanup errors
    }
    if (Test-Path $COMPOSE_FILE) {
        Write-Host "Stopping Docker Compose services..."
        docker-compose -f $COMPOSE_FILE down 2>$null | Out-Null
    }
    if (Test-Path $COMPOSE_FILE) {
        Remove-Item $COMPOSE_FILE -ErrorAction SilentlyContinue
    }
}

try {
    Write-Host "=== Docker Compose Sessh Example ==="
    Write-Host "Service: $SERVICE_NAME"
    Write-Host ""

    # Check if Docker Compose is available
    if (-not (Get-Command docker-compose -ErrorAction SilentlyContinue)) {
        Write-Error "Error: docker-compose is required but not installed."
        exit 1
    }

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

    $SSH_PUBKEY = (Get-Content "$SSH_KEY_PATH.pub" -Raw).Trim()

    # Create docker-compose.yml
    # Use single-quoted here-string to prevent variable expansion, then replace manually
    $composeContent = @'
version: '3.8'
services:
  PLACEHOLDER_SERVICE_NAME:
    image: ubuntu:22.04
    ports:
      - "PLACEHOLDER_SSH_PORT:22"
    environment:
      - SSH_PUBKEY=PLACEHOLDER_SSH_PUBKEY
    command: >
      bash -c "
        apt-get update -qq &&
        apt-get install -y -qq openssh-server tmux sudo &&
        mkdir -p /var/run/sshd &&
        echo 'root:testpass' | chpasswd &&
        sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin yes/' /etc/ssh/sshd_config &&
        mkdir -p /root/.ssh &&
        echo "$SSH_PUBKEY" > /root/.ssh/authorized_keys &&
        chmod 700 /root/.ssh &&
        chmod 600 /root/.ssh/authorized_keys &&
        /usr/sbin/sshd -D
      "
'@
    $composeContent = $composeContent -replace 'PLACEHOLDER_SERVICE_NAME', $SERVICE_NAME
    $composeContent = $composeContent -replace 'PLACEHOLDER_SSH_PORT', $SSH_PORT
    # Replace placeholder with actual key (will be used in bash command)
    $composeContent = $composeContent -replace 'PLACEHOLDER_SSH_PUBKEY', $SSH_PUBKEY
    $composeContent | Set-Content -Path $COMPOSE_FILE

    # Start services
    Write-Host "Starting Docker Compose services..."
    # Set environment variable for docker-compose
    $env:SSH_PUBKEY = $SSH_PUBKEY
    docker-compose -f $COMPOSE_FILE up -d

    # Wait for SSH to be ready
    Write-Host "Waiting for SSH server to be ready..."
    Write-Host "This may take 30-60 seconds while packages install..."
    
    $maxWaitAttempts = 120
    $attempt = 0
    $sshdRunning = $false
    
    while ($attempt -lt $maxWaitAttempts -and -not $sshdRunning) {
        Start-Sleep -Seconds 2
        $containerId = docker-compose -f $COMPOSE_FILE ps -q $SERVICE_NAME 2>$null
        if ($containerId) {
            $sshdCheck = docker exec $containerId ps aux 2>$null | Select-String "sshd"
            if ($sshdCheck) {
                $sshdRunning = $true
                Write-Host "SSH daemon detected in container"
                break
            }
        }
        $attempt++
        if ($attempt % 10 -eq 0) {
            Write-Host "Waiting for package installation... ($attempt/$maxWaitAttempts)"
        }
    }
    
    if (-not $sshdRunning) {
        Write-Host "Container logs:"
        docker-compose -f $COMPOSE_FILE logs $SERVICE_NAME 2>&1 | Select-Object -Last 30
        Write-Error "SSH daemon did not start in container."
        exit 1
    }
    
    Write-Host "Testing SSH connection..."
    Start-Sleep -Seconds 3
    $maxAttempts = 30
    $attempt = 0
    $sshReady = $false
    while ($attempt -lt $maxAttempts -and -not $sshReady) {
        $null = ssh.exe -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=NUL -o LogLevel=ERROR -p $SSH_PORT root@localhost "echo ready" 2>&1
        if ($LASTEXITCODE -eq 0) {
            $sshReady = $true
            Write-Host "SSH server is ready!"
            break
        }
        Start-Sleep -Seconds 2
        $attempt++
        if ($attempt % 5 -eq 0) {
            Write-Host "Testing SSH connection... (attempt $attempt/$maxAttempts)"
        }
    }
    
    if (-not $sshReady) {
        Write-Error "SSH server did not become ready in time."
        exit 1
    }

    # Get container info
    $CONTAINER_ID = docker-compose -f $COMPOSE_FILE ps -q $SERVICE_NAME
    Write-Host "Container ID: $CONTAINER_ID"

    # Open session
    Write-Host "Opening sessh session..."
    & $SESSH_BIN open $ALIAS "root@localhost" $SSH_PORT

    # Run commands
    Write-Host "Running commands..."
    & $SESSH_BIN 'run' $ALIAS 'root@localhost' '--' "echo 'Hello from Docker Compose service!'" | Out-Null
    Start-Sleep -Seconds 2
    & $SESSH_BIN 'run' $ALIAS 'root@localhost' '--' "hostname" | Out-Null
    Start-Sleep -Seconds 2
    & $SESSH_BIN 'run' $ALIAS 'root@localhost' '--' "apt-get update -qq" | Out-Null
    Start-Sleep -Seconds 3
    & $SESSH_BIN 'run' $ALIAS 'root@localhost' '--' "which tmux" | Out-Null
    Start-Sleep -Seconds 2
    & $SESSH_BIN 'run' $ALIAS 'root@localhost' '--' "cd /tmp && pwd && echo 'State persisted across commands!'" | Out-Null
    Start-Sleep -Seconds 2

    # Get logs
    Write-Host ""
    Write-Host "=== Session Logs ==="
    Start-Sleep -Seconds 2
    & $SESSH_BIN 'logs' $ALIAS 'root@localhost' 50

    # Check status
    Write-Host ""
    Write-Host "=== Session Status ==="
    & $SESSH_BIN 'status' $ALIAS 'root@localhost' $SSH_PORT

    # Show Docker Compose status
    Write-Host ""
    Write-Host "=== Docker Compose Status ==="
    docker-compose -f $COMPOSE_FILE ps

    Write-Host ""
    Write-Host "Example completed successfully!"
} finally {
    Cleanup
}

