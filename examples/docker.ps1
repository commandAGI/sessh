# Example: Using sessh with a Docker container (PowerShell version)
# This demonstrates sessh usage with a Docker container that runs an SSH server

$ErrorActionPreference = "Continue"  # Change to Continue to allow script to continue despite ControlMaster errors

# Configuration
$CONTAINER_NAME = "sessh-test-$(Get-Date -Format 'yyyyMMddHHmmss')"
$IMAGE = "ubuntu:22.04"
$ALIAS = "docker-test"
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
            $env:PORT = $SSH_PORT
            & $SESSH_BIN close $ALIAS "root@localhost" $SSH_PORT 2>&1 | Out-Null
        }
    } catch {
        # Ignore cleanup errors
    }
    docker stop $CONTAINER_NAME 2>$null | Out-Null
    docker rm $CONTAINER_NAME 2>$null | Out-Null
}

try {
    Write-Host "=== Docker Sessh Example ==="
    Write-Host "Container: $CONTAINER_NAME"
    Write-Host "SSH Port: $SSH_PORT"
    Write-Host ""

    # Check if Docker is available
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
        Write-Error "Error: docker is required but not installed."
        exit 1
    }
    
    # Clean up any existing containers with same name pattern
    docker ps -a --filter "name=sessh-test" -q | ForEach-Object { 
        docker rm -f $_ 2>$null | Out-Null 
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

    # Start Docker container with SSH server
    Write-Host "Starting Docker container with SSH server..."
    $containerId = docker run -d `
        --name $CONTAINER_NAME `
        -p "${SSH_PORT}:22" `
        -e "SSH_PUBKEY=$SSH_PUBKEY" `
        $IMAGE `
        bash -c "apt-get update -qq && apt-get install -y -qq openssh-server tmux sudo && mkdir -p /var/run/sshd && echo 'root:testpass' | chpasswd && sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin yes/' /etc/ssh/sshd_config && mkdir -p /root/.ssh && echo `"`${SSH_PUBKEY}`" > /root/.ssh/authorized_keys && chmod 700 /root/.ssh && chmod 600 /root/.ssh/authorized_keys && /usr/sbin/sshd -D"
    
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Failed to start Docker container"
        exit 1
    }
    
    Write-Host "Container started: $containerId"

    # Wait for container to be ready
    Write-Host "Waiting for SSH server to be ready..."
    Write-Host "This may take 30-60 seconds while packages install..."
    
    # First, wait for container to finish installing packages
    # Check if sshd is running in the container
    $maxWaitAttempts = 120  # 2 minutes total
    $attempt = 0
    $sshdRunning = $false
    
    while ($attempt -lt $maxWaitAttempts -and -not $sshdRunning) {
        Start-Sleep -Seconds 2
        
        # Check if container is still running
        $containerStatus = docker inspect --format='{{.State.Status}}' $CONTAINER_NAME 2>$null
        if ($containerStatus -ne "running") {
            Write-Host "Container status: $containerStatus"
            Write-Host "Container logs:"
            docker logs $CONTAINER_NAME 2>&1 | Select-Object -Last 30
            Write-Error "Container is not running. Check logs above."
            exit 1
        }
        
        # Check if sshd process is running
        $sshdCheck = docker exec $CONTAINER_NAME ps aux 2>$null | Select-String "sshd"
        if ($sshdCheck) {
            $sshdRunning = $true
            Write-Host "SSH daemon detected in container"
            break
        }
        
        $attempt++
        if ($attempt % 10 -eq 0) {
            Write-Host "Waiting for package installation... ($attempt/$maxWaitAttempts)"
        }
    }
    
    if (-not $sshdRunning) {
        Write-Host "Container logs:"
        docker logs $CONTAINER_NAME 2>&1 | Select-Object -Last 30
        Write-Error "SSH daemon did not start in container."
        exit 1
    }
    
    # Now test SSH connection
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
        Write-Host "Container logs (last 30 lines):"
        docker logs $CONTAINER_NAME 2>&1 | Select-Object -Last 30
        Write-Host "SSH connection test failed. Checking container:"
        docker exec $CONTAINER_NAME netstat -tuln 2>&1 | Select-Object -First 10
        Write-Error "SSH server did not become ready in time."
        exit 1
    }

    # Open session
    Write-Host "Opening sessh session..."
    $env:PORT = $SSH_PORT
    & $SESSH_BIN open $ALIAS "root@localhost" $SSH_PORT

    # Run commands
    Write-Host "Running commands..."
    $env:PORT = $SSH_PORT
    
    Write-Host "Running: echo command..."
    & $SESSH_BIN 'run' $ALIAS 'root@localhost' '--' "echo 'Hello from Docker container!'" | Out-Null
    Start-Sleep -Seconds 2
    
    Write-Host "Running: apt-get update..."
    & $SESSH_BIN 'run' $ALIAS 'root@localhost' '--' "apt-get update -qq" | Out-Null
    Start-Sleep -Seconds 3
    
    Write-Host "Running: which tmux..."
    & $SESSH_BIN 'run' $ALIAS 'root@localhost' '--' "which tmux" | Out-Null
    Start-Sleep -Seconds 2
    
    Write-Host "Running: cd /tmp && pwd..."
    & $SESSH_BIN 'run' $ALIAS 'root@localhost' '--' "cd /tmp && pwd && echo 'State persisted across commands!'" | Out-Null
    Start-Sleep -Seconds 2

    # Get logs
    Write-Host ""
    Write-Host "=== Session Logs ==="
    $env:PORT = $SSH_PORT
    Start-Sleep -Seconds 2  # Give commands time to complete
    & $SESSH_BIN 'logs' $ALIAS 'root@localhost' 50

    # Check status
    Write-Host ""
    Write-Host "=== Session Status ==="
    $env:PORT = $SSH_PORT
    & $SESSH_BIN 'status' $ALIAS 'root@localhost' $SSH_PORT

    Write-Host ""
    Write-Host "Example completed successfully!"
} finally {
    Cleanup
}

