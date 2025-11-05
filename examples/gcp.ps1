# Example: Using sessh with Google Cloud Platform Compute Engine (PowerShell version)
# This demonstrates launching a GCP instance, using sessh to train a model, and terminating it

$ErrorActionPreference = "Stop"

# Configuration
$GCP_PROJECT = if ($env:GCP_PROJECT) { $env:GCP_PROJECT } else { "" }
$GCP_ZONE = if ($env:GCP_ZONE) { $env:GCP_ZONE } else { "us-central1-a" }
$INSTANCE_TYPE = if ($env:GCP_INSTANCE_TYPE) { $env:GCP_INSTANCE_TYPE } else { "n1-standard-1" }
$IMAGE_PROJECT = if ($env:GCP_IMAGE_PROJECT) { $env:GCP_IMAGE_PROJECT } else { "ubuntu-os-cloud" }
$IMAGE_FAMILY = if ($env:GCP_IMAGE_FAMILY) { $env:GCP_IMAGE_FAMILY } else { "ubuntu-2204-lts" }
$INSTANCE_NAME = "sessh-example-$(Get-Date -Format 'yyyyMMddHHmmss')"
$ALIAS = "gcp-agent"
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
if (-not (Get-Command gcloud -ErrorAction SilentlyContinue)) {
    Write-Error "Error: gcloud CLI is required but not installed."
    exit 1
}

if ([string]::IsNullOrEmpty($GCP_PROJECT)) {
    $projectCheck = gcloud config get-value project 2>$null
    if ($projectCheck -and $projectCheck -ne "None") {
        $GCP_PROJECT = $projectCheck
    } else {
        Write-Error "Error: GCP_PROJECT must be set or gcloud must be configured."
        exit 1
    }
}

$IP = ""

function Cleanup {
    Write-Host "Cleaning up..."
    if ($ALIAS -and $IP) {
        & $SESSH_BIN close $ALIAS "ubuntu@${IP}" 2>$null | Out-Null
    }
    if ($INSTANCE_NAME) {
        Write-Host "Deleting GCP instance: $INSTANCE_NAME"
        gcloud compute instances delete $INSTANCE_NAME `
            --zone=$GCP_ZONE `
            --project=$GCP_PROJECT `
            --quiet 2>$null | Out-Null
    }
}

try {
    Write-Host "=== GCP Compute Engine Sessh Example ==="
    Write-Host "Project: $GCP_PROJECT"
    Write-Host "Zone: $GCP_ZONE"
    Write-Host "Instance Type: $INSTANCE_TYPE"
    Write-Host "Image: $IMAGE_PROJECT/$IMAGE_FAMILY"
    Write-Host ""

    # Launch instance
    Write-Host "Creating GCP instance..."
    gcloud compute instances create $INSTANCE_NAME `
        --zone=$GCP_ZONE `
        --machine-type=$INSTANCE_TYPE `
        --image-project=$IMAGE_PROJECT `
        --image-family=$IMAGE_FAMILY `
        --project=$GCP_PROJECT `
        --metadata=enable-oslogin=FALSE `
        --tags=sessh-example 2>$null | Out-Null

    # Get IP address
    Write-Host "Getting instance IP address..."
    $maxAttempts = 30
    $attempt = 0
    while ($attempt -lt $maxAttempts) {
        $ipRaw = gcloud compute instances describe $INSTANCE_NAME `
            --zone=$GCP_ZONE `
            --project=$GCP_PROJECT `
            --format='get(networkInterfaces[0].accessConfigs[0].natIP)' 2>$null

        if ($ipRaw -and $ipRaw -ne "None") {
            $IP = $ipRaw
            break
        }
        Start-Sleep -Seconds 2
        $attempt++
    }

    if ([string]::IsNullOrEmpty($IP) -or $IP -eq "None") {
        Write-Error "Error: Failed to get instance IP address."
        exit 1
    }

    Write-Host "Instance IP: $IP"

    # Wait for SSH to be ready
    Write-Host "Waiting for SSH to be ready..."
    $maxAttempts = 60
    $attempt = 0
    while ($attempt -lt $maxAttempts) {
        $sshTest = gcloud compute ssh $INSTANCE_NAME `
            --zone=$GCP_ZONE `
            --project=$GCP_PROJECT `
            --command="echo ready" `
            --quiet 2>$null
        if ($LASTEXITCODE -eq 0) {
            break
        }
        Start-Sleep -Seconds 5
        $attempt++
    }

    # For sessh, we need to use the IP directly
    # Wait for direct SSH access
    $maxAttempts = 60
    $attempt = 0
    while ($attempt -lt $maxAttempts) {
        $sshTest = ssh.exe -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new "ubuntu@${IP}" "echo ready" 2>$null
        if ($LASTEXITCODE -eq 0) {
            break
        }
        Start-Sleep -Seconds 5
        $attempt++
    }

    # Open session
    Write-Host "Opening sessh session..."
    & $SESSH_BIN open $ALIAS "ubuntu@${IP}"

    # Install dependencies and run workload
    Write-Host "Installing dependencies..."
    & $SESSH_BIN run $ALIAS "ubuntu@${IP}" -- "sudo apt-get update -qq"
    & $SESSH_BIN run $ALIAS "ubuntu@${IP}" -- "sudo apt-get install -y -qq python3-pip tmux"

    Write-Host "Running workload..."
    & $SESSH_BIN run $ALIAS "ubuntu@${IP}" -- "python3 -c `"import sys; print(f'Python version: {sys.version}')`""
    & $SESSH_BIN run $ALIAS "ubuntu@${IP}" -- "cd /tmp && pwd && echo 'Working directory: $(pwd)' && echo 'State persisted across commands!'"

    # Get logs
    Write-Host ""
    Write-Host "=== Session Logs ==="
    & $SESSH_BIN logs $ALIAS "ubuntu@${IP}" 100

    # Check status
    Write-Host ""
    Write-Host "=== Session Status ==="
    & $SESSH_BIN status $ALIAS "ubuntu@${IP}"

    Write-Host ""
    Write-Host "Example completed successfully!"
    Write-Host "Instance $INSTANCE_NAME will be deleted on exit."
} finally {
    Cleanup
}

