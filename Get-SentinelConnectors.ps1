#Requires -RunAsAdministrator

<#
.SYNOPSIS
    Lists Microsoft Sentinel data connectors from a selected workspace.

.DESCRIPTION
    - Checks for Azure CLI and installs it if missing.
    - Logs into Azure interactively.
    - Presents numbered menus to select subscription, resource group, workspace, etc.
    - Extracts and displays Sentinel data connector information.
#>

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

#region ── Helper: Numbered Selector ──────────────────────────────────────────

function Show-Menu {
    param(
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][array]$Items,
        [Parameter(Mandatory)][string]$DisplayProperty
    )

    Write-Host "" 
    Write-Host "  ============================================================" -ForegroundColor Cyan
    Write-Host "    $Title" -ForegroundColor Cyan
    Write-Host "  ============================================================" -ForegroundColor Cyan

    for ($i = 0; $i -lt $Items.Count; $i++) {
        $display = $Items[$i].$DisplayProperty
        Write-Host "  [$($i + 1)] $display" -ForegroundColor Yellow
    }

    do {
        $choice = Read-Host "`n  Enter number (1-$($Items.Count))"
        $parsed = 0
        $valid = [int]::TryParse($choice, [ref]$parsed) -and $parsed -ge 1 -and $parsed -le $Items.Count
        if (-not $valid) {
            Write-Host "  Invalid selection. Try again." -ForegroundColor Red
        }
    } while (-not $valid)

    return $Items[$parsed - 1]
}

#endregion

#region ── Step 1: Ensure Azure CLI is installed ──────────────────────────────

Write-Host "`n[1/5] Checking for Azure CLI..." -ForegroundColor Green

$azCmd = Get-Command az -ErrorAction SilentlyContinue

if (-not $azCmd) {
    Write-Host "  Azure CLI not found. Downloading and installing..." -ForegroundColor Yellow

    $installerUrl  = 'https://aka.ms/installazurecliwindowsx64'
    $installerPath = Join-Path $env:TEMP 'AzureCLI.msi'

    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $installerUrl -OutFile $installerPath -UseBasicParsing

        Write-Host "  Running installer (this may take a minute)..." -ForegroundColor Yellow
        $msiArgs = @('/i', $installerPath, '/quiet', '/norestart')
        $proc = Start-Process msiexec.exe -ArgumentList $msiArgs -Wait -PassThru

        if ($proc.ExitCode -ne 0) {
            throw "MSI installer exited with code $($proc.ExitCode)."
        }

        # Refresh PATH so az is discoverable in this session
        $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
        $userPath    = [Environment]::GetEnvironmentVariable('Path', 'User')
        $env:Path    = "$machinePath;$userPath"

        $azCmd = Get-Command az -ErrorAction SilentlyContinue
        if (-not $azCmd) {
            throw "Azure CLI installed but 'az' still not found on PATH. Please restart your terminal and try again."
        }

        Write-Host "  Azure CLI installed successfully." -ForegroundColor Green
    }
    finally {
        if (Test-Path $installerPath) { Remove-Item $installerPath -Force -ErrorAction SilentlyContinue }
    }
}
else {
    $azVersion = (az version 2>$null | ConvertFrom-Json).'azure-cli'
    Write-Host "  Azure CLI found (v$azVersion)." -ForegroundColor Green
}

#endregion

#region ── Step 2: Ensure sentinel extension is installed ─────────────────────

Write-Host "`n[2/5] Ensuring 'sentinel' Azure CLI extension is available..." -ForegroundColor Green

$extensions = az extension list 2>$null | ConvertFrom-Json
$hasSentinel = $extensions | Where-Object { $_.name -eq 'sentinel' }

if (-not $hasSentinel) {
    Write-Host "  Installing 'sentinel' extension..." -ForegroundColor Yellow
    az extension add --name sentinel --yes 2>$null
    Write-Host "  Extension installed." -ForegroundColor Green
}
else {
    Write-Host "  Extension already installed." -ForegroundColor Green
}

#endregion

#region ── Step 3: Login to Azure ─────────────────────────────────────────────

Write-Host "`n[3/5] Logging in to Azure..." -ForegroundColor Green

# Check if already logged in
$account = az account show 2>$null | ConvertFrom-Json -ErrorAction SilentlyContinue

if ($account) {
    Write-Host "  Already logged in as: $($account.user.name)" -ForegroundColor Green
    $reuse = Read-Host "  Use this session? (Y/n)"
    if ($reuse -match '^[Nn]') {
        az login --only-show-errors | Out-Null
    }
}
else {
    az login --only-show-errors | Out-Null
}

#endregion

#region ── Step 4: Select subscription → resource group → workspace ───────────

Write-Host "`n[4/5] Discovering Azure resources..." -ForegroundColor Green

# ── Subscription ──
Write-Host "  Fetching subscriptions..." -ForegroundColor Gray
$subscriptions = az account list --query "[?state=='Enabled']" 2>$null | ConvertFrom-Json

if (-not $subscriptions -or $subscriptions.Count -eq 0) {
    Write-Error "No enabled Azure subscriptions found."
}

$selectedSub = if ($subscriptions.Count -eq 1) {
    Write-Host "  Auto-selected single subscription: $($subscriptions[0].name)" -ForegroundColor Green
    $subscriptions[0]
}
else {
    Show-Menu -Title 'Select a Subscription' -Items $subscriptions -DisplayProperty 'name'
}

az account set --subscription $selectedSub.id 2>$null
Write-Host "  Subscription set: $($selectedSub.name)" -ForegroundColor Green

# ── Resource Group ──
Write-Host "  Fetching resource groups..." -ForegroundColor Gray
$resourceGroups = az group list --query "[].{name:name, location:location}" 2>$null | ConvertFrom-Json

if (-not $resourceGroups -or $resourceGroups.Count -eq 0) {
    Write-Error "No resource groups found in subscription '$($selectedSub.name)'."
}

$selectedRg = if ($resourceGroups.Count -eq 1) {
    Write-Host "  Auto-selected single resource group: $($resourceGroups[0].name)" -ForegroundColor Green
    $resourceGroups[0]
}
else {
    Show-Menu -Title 'Select a Resource Group' -Items $resourceGroups -DisplayProperty 'name'
}

# ── Log Analytics Workspace (Sentinel sits on top of one) ──
Write-Host "  Fetching Log Analytics workspaces in '$($selectedRg.name)'..." -ForegroundColor Gray
$workspaces = az monitor log-analytics workspace list --resource-group $selectedRg.name 2>$null | ConvertFrom-Json

if (-not $workspaces -or $workspaces.Count -eq 0) {
    Write-Error "No Log Analytics workspaces found in resource group '$($selectedRg.name)'."
}

$selectedWs = if ($workspaces.Count -eq 1) {
    Write-Host "  Auto-selected single workspace: $($workspaces[0].name)" -ForegroundColor Green
    $workspaces[0]
}
else {
    Show-Menu -Title 'Select a Log Analytics Workspace' -Items $workspaces -DisplayProperty 'name'
}

#endregion

#region ── Step 5: List Sentinel Data Connectors ──────────────────────────────

Write-Host "`n[5/5] Retrieving Sentinel data connectors..." -ForegroundColor Green

$connectors = az sentinel data-connector list `
    --resource-group $selectedRg.name `
    --workspace-name $selectedWs.name 2>$null | ConvertFrom-Json

if (-not $connectors -or $connectors.Count -eq 0) {
    Write-Host "`n  No data connectors found in workspace '$($selectedWs.name)'." -ForegroundColor Yellow
    exit 0
}

Write-Host "`n  Found $($connectors.Count) data connector(s).`n" -ForegroundColor Green

# ── Build a summary table ──
$report = foreach ($c in $connectors) {
    [PSCustomObject]@{
        Name          = $c.name
        Kind          = $c.kind
        ConnectorId   = $c.id -replace '.*/dataConnectors/', ''
        TenantId      = $c.properties.tenantId
        State         = $c.properties.dataTypes.PSObject.Properties |
                            ForEach-Object { "$($_.Name): $($_.Value.state)" }
    }
}

$report | Format-Table -AutoSize -Wrap

# ── Optional: drill into a specific connector ──
$drill = Read-Host "View full JSON for a specific connector? (Y/n)"
if ($drill -notmatch '^[Nn]') {
    $chosen = Show-Menu -Title 'Select a Connector' -Items $connectors -DisplayProperty 'name'
    $chosen | ConvertTo-Json -Depth 10 | Write-Host -ForegroundColor White
}

Write-Host "`nDone." -ForegroundColor Green

#endregion
