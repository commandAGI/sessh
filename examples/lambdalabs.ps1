# Example: Using sessh with Lambda Labs GPU instances (PowerShell version)
# This demonstrates launching a Lambda Labs GPU instance, using sessh to train a model, and terminating it

$ErrorActionPreference = "Stop"

# Configuration
$LAMBDA_API_KEY = if ($env:LAMBDA_API_KEY) { $env:LAMBDA_API_KEY } else { "" }
$LAMBDA_REGION = if ($env:LAMBDA_REGION) { $env:LAMBDA_REGION } else { "us-west-1" }
$LAMBDA_INSTANCE_TYPE = if ($env:LAMBDA_INSTANCE_TYPE) { $env:LAMBDA_INSTANCE_TYPE } else { "gpu_1x_a10" }
$LAMBDA_SSH_KEY = if ($env:LAMBDA_SSH_KEY) { $env:LAMBDA_SSH_KEY } else { "" }
$ALIAS = "lambda-agent"
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
if (-not (Get-Command curl -ErrorAction SilentlyContinue)) {
    Write-Error "Error: curl is required but not installed."
    exit 1
}

# Check for jq or python3 for JSON parsing
$hasJsonParser = (Get-Command jq -ErrorAction SilentlyContinue) -or (Get-Command python3 -ErrorAction SilentlyContinue)
if (-not $hasJsonParser) {
    Write-Warning "jq or python3 not found. JSON parsing may be limited."
}

if ([string]::IsNullOrEmpty($LAMBDA_API_KEY)) {
    Write-Error "Error: LAMBDA_API_KEY environment variable must be set with your Lambda Labs API key."
    exit 1
}

if ([string]::IsNullOrEmpty($LAMBDA_SSH_KEY)) {
    Write-Error "Error: LAMBDA_SSH_KEY environment variable must be set with your Lambda Labs SSH key name."
    exit 1
}

$INSTANCE_ID = ""
$IP = ""

function Cleanup {
    Write-Host "Cleaning up..."
    if ($ALIAS -and $IP) {
        & $SESSH_BIN close $ALIAS "ubuntu@${IP}" 2>$null | Out-Null
    }
    if ($INSTANCE_ID) {
        Write-Host "Terminating Lambda Labs instance: $INSTANCE_ID"
        $body = @{ instance_ids = @($INSTANCE_ID) } | ConvertTo-Json -Compress
        curl.exe -su "${LAMBDA_API_KEY}:" `
            -H "content-type: application/json" `
            -X POST https://cloud.lambdalabs.com/api/v1/instance-operations/terminate `
            -d $body 2>$null | Out-Null
    }
}

try {
    Write-Host "=== Lambda Labs GPU Sessh Example ==="
    Write-Host "Region: $LAMBDA_REGION"
    Write-Host "Instance Type: $LAMBDA_INSTANCE_TYPE"
    Write-Host "SSH Key: $LAMBDA_SSH_KEY"
    Write-Host ""

    # Launch instance
    Write-Host "Launching Lambda Labs instance..."
    $launchBody = @{
        region_name = $LAMBDA_REGION
        instance_type_name = $LAMBDA_INSTANCE_TYPE
        ssh_key_names = @($LAMBDA_SSH_KEY)
        quantity = 1
    } | ConvertTo-Json -Compress

    $response = curl.exe -su "${LAMBDA_API_KEY}:" `
        -H "content-type: application/json" `
        -X POST https://cloud.lambdalabs.com/api/v1/instance-operations/launch `
        -d $launchBody

    # Parse response
    if (Get-Command jq -ErrorAction SilentlyContinue) {
        $instanceIdRaw = $response | jq -r '.data.instance_ids[0]'
    } elseif (Get-Command python3 -ErrorAction SilentlyContinue) {
        $instanceIdRaw = $response | python3 -c "import sys, json; print(json.load(sys.stdin)['data']['instance_ids'][0])"
    } else {
        # Fallback: try to extract from JSON manually
        if ($response -match '"instance_ids"\s*:\s*\[\s*"([^"]+)"') {
            $instanceIdRaw = $matches[1]
        } else {
            Write-Error "Error: Failed to launch instance. Response: $response"
            exit 1
        }
    }

    if ([string]::IsNullOrEmpty($instanceIdRaw) -or $instanceIdRaw -eq "null") {
        Write-Error "Error: Failed to launch instance. Response: $response"
        exit 1
    }

    $INSTANCE_ID = $instanceIdRaw
    Write-Host "Instance ID: $INSTANCE_ID"

    # Wait for IP
    Write-Host "Waiting for instance IP address..."
    $maxAttempts = 60
    $attempt = 0
    while ($attempt -lt $maxAttempts) {
        $instances = curl.exe -su "${LAMBDA_API_KEY}:" https://cloud.lambdalabs.com/api/v1/instances 2>$null

        if (Get-Command jq -ErrorAction SilentlyContinue) {
            $ipRaw = $instances | jq -r ".data[] | select(.id==`"$INSTANCE_ID`") | .ip"
        } elseif (Get-Command python3 -ErrorAction SilentlyContinue) {
            $ipRaw = $instances | python3 -c "import sys, json; data = json.load(sys.stdin)['data']; print(next((i['ip'] for i in data if i['id'] == '$INSTANCE_ID'), 'null'))"
        } else {
            # Fallback parsing
            if ($instances -match "`"id`"\s*:\s*`"$INSTANCE_ID`"[^}]*`"ip`"\s*:\s*`"([^`"]+)`"") {
                $ipRaw = $matches[1]
            } else {
                $ipRaw = "null"
            }
        }

        if ($ipRaw -and $ipRaw -ne "null" -and $ipRaw -ne "") {
            $IP = $ipRaw
            break
        }
        Start-Sleep -Seconds 5
        $attempt++
    }

    if ([string]::IsNullOrEmpty($IP) -or $IP -eq "null") {
        Write-Error "Error: Failed to get instance IP address."
        exit 1
    }

    Write-Host "Instance IP: $IP"

    # Wait for SSH to be ready
    Write-Host "Waiting for SSH to be ready..."
    $maxAttempts = 60
    $attempt = 0
    while ($attempt -lt $maxAttempts) {
        $sshTest = ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new "ubuntu@${IP}" "echo ready" 2>$null
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
    & $SESSH_BIN run $ALIAS "ubuntu@${IP}" -- "pip install torch torchvision"
    & $SESSH_BIN run $ALIAS "ubuntu@${IP}" -- "python3 -c `"import torch; print(f'PyTorch version: {torch.__version__}')`""

    Write-Host "Running workload..."
    & $SESSH_BIN run $ALIAS "ubuntu@${IP}" -- "cd /tmp && pwd && echo 'Working directory: $(pwd)' && echo 'State persisted across commands!'"
    & $SESSH_BIN run $ALIAS "ubuntu@${IP}" -- "nvidia-smi || echo 'GPU check (may not be available in all instance types)'"

    # Get logs
    Write-Host ""
    Write-Host "=== Session Logs ==="
    & $SESSH_BIN logs $ALIAS "ubuntu@${IP}" 200

    # Check status
    Write-Host ""
    Write-Host "=== Session Status ==="
    & $SESSH_BIN status $ALIAS "ubuntu@${IP}"

    Write-Host ""
    Write-Host "Example completed successfully!"
    Write-Host "Instance $INSTANCE_ID will be terminated on exit."
} finally {
    Cleanup
}

