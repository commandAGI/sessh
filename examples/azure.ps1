# Example: Using sessh with Microsoft Azure Virtual Machines (PowerShell version)
# This demonstrates launching an Azure VM, using sessh to train a model, and terminating it

$ErrorActionPreference = "Stop"

# Configuration
$AZURE_RESOURCE_GROUP = if ($env:AZURE_RESOURCE_GROUP) { $env:AZURE_RESOURCE_GROUP } else { "sessh-example-rg" }
$AZURE_LOCATION = if ($env:AZURE_LOCATION) { $env:AZURE_LOCATION } else { "eastus" }
$AZURE_VM_SIZE = if ($env:AZURE_VM_SIZE) { $env:AZURE_VM_SIZE } else { "Standard_B1s" }
$AZURE_VM_NAME = if ($env:AZURE_VM_NAME) { $env:AZURE_VM_NAME } else { "sessh-example-$(Get-Date -Format 'yyyyMMddHHmmss')" }
$AZURE_IMAGE = if ($env:AZURE_IMAGE) { $env:AZURE_IMAGE } else { "Ubuntu2204" }
$ALIAS = "azure-agent"
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
if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    Write-Error "Error: Azure CLI is required but not installed."
    exit 1
}

# Check if logged in
$accountCheck = az account show 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Error "Error: Not logged in to Azure. Run 'az login' first."
    exit 1
}

$IP = ""
$CLEANUP_RG = $false

function Cleanup {
    Write-Host "Cleaning up..."
    if ($ALIAS -and $IP) {
        & $SESSH_BIN close $ALIAS "azureuser@${IP}" 2>$null | Out-Null
    }
    if ($AZURE_VM_NAME) {
        Write-Host "Deleting Azure VM: $AZURE_VM_NAME"
        az vm delete `
            --resource-group $AZURE_RESOURCE_GROUP `
            --name $AZURE_VM_NAME `
            --yes 2>$null | Out-Null
    }
    if ($CLEANUP_RG) {
        Write-Host "Deleting resource group: $AZURE_RESOURCE_GROUP"
        az group delete --name $AZURE_RESOURCE_GROUP --yes --no-wait 2>$null | Out-Null
    }
}

try {
    Write-Host "=== Azure VM Sessh Example ==="
    Write-Host "Resource Group: $AZURE_RESOURCE_GROUP"
    Write-Host "Location: $AZURE_LOCATION"
    Write-Host "VM Size: $AZURE_VM_SIZE"
    Write-Host "VM Name: $AZURE_VM_NAME"
    Write-Host ""

    # Check if resource group exists, create if not
    $rgCheck = az group show --name $AZURE_RESOURCE_GROUP 2>$null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Creating resource group..."
        az group create --name $AZURE_RESOURCE_GROUP --location $AZURE_LOCATION 2>$null | Out-Null
        $CLEANUP_RG = $true
    }

    # Generate SSH key if needed
    $SSH_KEY_PATH = "$env:USERPROFILE\.ssh\id_rsa"
    if (-not (Test-Path $SSH_KEY_PATH)) {
        Write-Host "Generating SSH key..."
        $sshDir = Split-Path $SSH_KEY_PATH
        if (-not (Test-Path $sshDir)) {
            New-Item -ItemType Directory -Path $sshDir -Force | Out-Null
        }
        ssh-keygen.exe -t rsa -b 4096 -f $SSH_KEY_PATH -N '""' -q
    }

    # Launch VM
    Write-Host "Creating Azure VM..."
    $vmOutput = az vm create `
        --resource-group $AZURE_RESOURCE_GROUP `
        --name $AZURE_VM_NAME `
        --image $AZURE_IMAGE `
        --size $AZURE_VM_SIZE `
        --admin-username azureuser `
        --ssh-key-values "$SSH_KEY_PATH.pub" `
        --public-ip-sku Standard `
        --output json | ConvertFrom-Json

    # Get IP address
    $IP = $vmOutput.publicIpAddress

    if ([string]::IsNullOrEmpty($IP) -or $IP -eq "null") {
        Write-Error "Error: Failed to get VM IP address."
        exit 1
    }

    Write-Host "VM IP: $IP"

    # Wait for SSH to be ready
    Write-Host "Waiting for SSH to be ready..."
    $maxAttempts = 60
    $attempt = 0
    while ($attempt -lt $maxAttempts) {
        $sshTest = ssh.exe -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new -i $SSH_KEY_PATH "azureuser@${IP}" "echo ready" 2>$null
        if ($LASTEXITCODE -eq 0) {
            break
        }
        Start-Sleep -Seconds 5
        $attempt++
    }

    # Open session
    Write-Host "Opening sessh session..."
    $env:SESSH_IDENTITY = $SSH_KEY_PATH
    & $SESSH_BIN open $ALIAS "azureuser@${IP}"

    # Install dependencies and run workload
    Write-Host "Installing dependencies..."
    & $SESSH_BIN run $ALIAS "azureuser@${IP}" -- "sudo apt-get update -qq"
    & $SESSH_BIN run $ALIAS "azureuser@${IP}" -- "sudo apt-get install -y -qq python3-pip tmux"

    Write-Host "Running workload..."
    & $SESSH_BIN run $ALIAS "azureuser@${IP}" -- "python3 -c `"import sys; print(f'Python version: {sys.version}')`""
    & $SESSH_BIN run $ALIAS "azureuser@${IP}" -- "cd /tmp && pwd && echo 'Working directory: $(pwd)' && echo 'State persisted across commands!'"

    # Get logs
    Write-Host ""
    Write-Host "=== Session Logs ==="
    & $SESSH_BIN logs $ALIAS "azureuser@${IP}" 100

    # Check status
    Write-Host ""
    Write-Host "=== Session Status ==="
    & $SESSH_BIN status $ALIAS "azureuser@${IP}"

    Write-Host ""
    Write-Host "Example completed successfully!"
    Write-Host "VM $AZURE_VM_NAME will be deleted on exit."
} finally {
    Cleanup
}

