# Example: Using sessh with AWS EC2 (PowerShell version)
# This demonstrates launching an EC2 instance, using sessh to train a model, and terminating it

$ErrorActionPreference = "Stop"

# Configuration
$env:AWS_REGION = if ($env:AWS_REGION) { $env:AWS_REGION } else { "us-east-1" }
$env:INSTANCE_TYPE = if ($env:INSTANCE_TYPE) { $env:INSTANCE_TYPE } else { "t2.micro" }
$KEY_NAME = if ($env:AWS_KEY_NAME) { $env:AWS_KEY_NAME } else { "" }
$SECURITY_GROUP = if ($env:AWS_SECURITY_GROUP) { $env:AWS_SECURITY_GROUP } else { "" }
$AMI_ID = if ($env:AWS_AMI_ID) { $env:AWS_AMI_ID } else { "" }
$ALIAS = "aws-agent"
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
$AWS_CMD = if ($env:AWS_CMD) { $env:AWS_CMD } else { "aws" }
if (-not (Get-Command $AWS_CMD -ErrorAction SilentlyContinue)) {
    # Try Windows AWS CLI path
    $awsPaths = @(
        "${env:ProgramFiles}\Amazon\AWSCLIV2\aws.exe",
        "${env:ProgramFiles(x86)}\Amazon\AWSCLIV2\aws.exe"
    )
    $found = $false
    foreach ($path in $awsPaths) {
        if (Test-Path $path) {
            $AWS_CMD = $path
            $found = $true
            break
        }
    }
    if (-not $found) {
        Write-Error "Error: AWS CLI is required but not installed."
        exit 1
    }
}

# Check for jq (optional, but helpful)
if (-not (Get-Command jq -ErrorAction SilentlyContinue) -and -not (Get-Command python3 -ErrorAction SilentlyContinue)) {
    Write-Warning "jq or python3 not found. JSON parsing may be limited."
}

# Get default values if not set
if ([string]::IsNullOrEmpty($KEY_NAME)) {
    $keyPair = & $AWS_CMD ec2 describe-key-pairs --query 'KeyPairs[0].KeyName' --output text --region $env:AWS_REGION 2>$null
    if ($keyPair -and $keyPair -ne "None") {
        $KEY_NAME = $keyPair
    } else {
        Write-Error "Error: AWS_KEY_NAME must be set or at least one key pair must exist."
        exit 1
    }
}

if ([string]::IsNullOrEmpty($AMI_ID)) {
    $amiQuery = & $AWS_CMD ec2 describe-images `
        --owners 099720109477 `
        --filters "Name=name,Values=ubuntu/images/h2-ssd/ubuntu-jammy-22.04-amd64-server-*" "Name=state,Values=available" `
        --query "Images | sort_by(@, &CreationDate) | [-1].ImageId" `
        --output text `
        --region $env:AWS_REGION 2>$null
    
    if ($amiQuery -and $amiQuery -ne "None") {
        $AMI_ID = $amiQuery
    } else {
        Write-Error "Error: Failed to find Ubuntu 22.04 AMI. Please set AWS_AMI_ID manually."
        exit 1
    }
}

if ([string]::IsNullOrEmpty($SECURITY_GROUP)) {
    $sgQuery = & $AWS_CMD ec2 describe-security-groups `
        --filters "Name=ip-permission.from-port,Values=22" "Name=ip-permission.to-port,Values=22" "Name=ip-permission.protocol,Values=tcp" `
        --query 'SecurityGroups[0].GroupId' `
        --output text `
        --region $env:AWS_REGION 2>$null
    
    if ($sgQuery -and $sgQuery -ne "None") {
        $SECURITY_GROUP = $sgQuery
    } else {
        Write-Error "Error: AWS_SECURITY_GROUP must be set or a security group allowing SSH must exist."
        exit 1
    }
}

$INSTANCE_ID = ""
$IP = ""

function Cleanup {
    Write-Host "Cleaning up..."
    if ($ALIAS -and $IP) {
        & $SESSH_BIN close $ALIAS "ubuntu@${IP}" 2>$null | Out-Null
    }
    if ($INSTANCE_ID) {
        Write-Host "Terminating EC2 instance: $INSTANCE_ID"
        & $AWS_CMD ec2 terminate-instances --instance-ids $INSTANCE_ID --region $env:AWS_REGION 2>$null | Out-Null
    }
}

# Register cleanup
try {
    Write-Host "=== AWS EC2 Sessh Example ==="
    Write-Host "Region: $env:AWS_REGION"
    Write-Host "Instance Type: $env:INSTANCE_TYPE"
    Write-Host "AMI: $AMI_ID"
    Write-Host "Key Name: $KEY_NAME"
    Write-Host "Security Group: $SECURITY_GROUP"
    Write-Host ""

    # Launch instance
    Write-Host "Launching EC2 instance..."
    $launchOutput = & $AWS_CMD ec2 run-instances `
        --image-id $AMI_ID `
        --instance-type $env:INSTANCE_TYPE `
        --key-name $KEY_NAME `
        --security-group-ids $SECURITY_GROUP `
        --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=sessh-example}]" `
        --region $env:AWS_REGION `
        --output json | ConvertFrom-Json
    
    $INSTANCE_ID = $launchOutput.Instances[0].InstanceId
    Write-Host "Instance ID: $INSTANCE_ID"

    # Wait for instance to be running
    Write-Host "Waiting for instance to be running..."
    & $AWS_CMD ec2 wait instance-running --instance-ids $INSTANCE_ID --region $env:AWS_REGION

    # Get IP address
    Write-Host "Getting instance IP address..."
    $maxAttempts = 30
    $attempt = 0
    while ($attempt -lt $maxAttempts) {
        $instanceInfo = & $AWS_CMD ec2 describe-instances `
            --instance-ids $INSTANCE_ID `
            --query 'Reservations[0].Instances[0].PublicIpAddress' `
            --output text `
            --region $env:AWS_REGION
        
        if ($instanceInfo -and $instanceInfo -ne "None" -and $instanceInfo -ne "") {
            $IP = $instanceInfo
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
    Write-Host "Instance $INSTANCE_ID will be terminated on exit."
} finally {
    Cleanup
}

