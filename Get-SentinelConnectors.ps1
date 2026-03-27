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
$ErrorActionPreference = 'Continue'

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

#region ── Step 4: Find all Sentinel instances via Azure Resource Graph ───────

Write-Host "`n[4/5] Discovering Sentinel instances..." -ForegroundColor Green

$currentAccount = az account show 2>$null | ConvertFrom-Json
$tenantId = $currentAccount.tenantId
Write-Host "  Tenant: $tenantId ($($currentAccount.user.name))" -ForegroundColor Gray

# Build a lookup of subscription names
$subLookup = @{}
$allSubs = az account list --all --query "[?state=='Enabled' && tenantId=='$tenantId'].{id:id, name:name}" 2>$null | ConvertFrom-Json
if ($allSubs) {
    foreach ($s in $allSubs) {
        if ($s) { $subLookup[$s.id] = $s.name }
    }
}
Write-Host "  Querying $($subLookup.Count) subscription(s) via Resource Graph..." -ForegroundColor Gray

# Use az rest to call Resource Graph API directly (no extension needed)
$graphBody = @{
    query   = "resources | where type == 'microsoft.operationsmanagement/solutions' | where name startswith 'SecurityInsights(' | project name, resourceGroup, subscriptionId, location"
    options = @{ resultFormat = "objectArray" }
} | ConvertTo-Json -Compress

$bodyFile = Join-Path $env:TEMP "sentinel_graph_query.json"
Set-Content -Path $bodyFile -Value $graphBody -Encoding UTF8

$rawResult = az rest --method post `
    --url "https://management.azure.com/providers/Microsoft.ResourceGraph/resources?api-version=2022-10-01" `
    --body "@$bodyFile" `
    --query "data" -o json 2>$null

Remove-Item $bodyFile -Force -ErrorAction SilentlyContinue

$graphResults = $rawResult | ConvertFrom-Json

if (-not $graphResults) {
    Write-Host "`n  No Sentinel instances found across any subscription in this tenant." -ForegroundColor Red
    exit 1
}

if ($graphResults -isnot [System.Array]) {
    $graphResults = @($graphResults)
}

$allSentinelWorkspaces = @()
foreach ($r in $graphResults) {
    if (-not $r) { continue }
    $wsName = $r.name -replace '^SecurityInsights\(', '' -replace '\)$', ''
    $subName = $subLookup[$r.subscriptionId]
    if (-not $subName) { $subName = $r.subscriptionId }
    $allSentinelWorkspaces += [PSCustomObject]@{
        displayName      = "$wsName  [$($r.resourceGroup) | $subName]"
        workspaceName    = $wsName
        resourceGroup    = $r.resourceGroup
        subscriptionId   = $r.subscriptionId
        subscriptionName = $subName
        location         = $r.location
    }
}

if ($allSentinelWorkspaces.Count -eq 0) {
    Write-Host "`n  No Sentinel instances found across any subscription in this tenant." -ForegroundColor Red
    exit 1
}

Write-Host "  Found $($allSentinelWorkspaces.Count) Sentinel workspace(s)." -ForegroundColor Green

$selectedSentinel = if ($allSentinelWorkspaces.Count -eq 1) {
    Write-Host "  Auto-selected: $($allSentinelWorkspaces[0].workspaceName)" -ForegroundColor Green
    $allSentinelWorkspaces[0]
}
else {
    Show-Menu -Title 'Select a Sentinel Workspace' -Items $allSentinelWorkspaces -DisplayProperty 'displayName'
}

az account set --subscription $selectedSentinel.subscriptionId 2>$null
$selectedRgName = $selectedSentinel.resourceGroup
$selectedWsName = $selectedSentinel.workspaceName
Write-Host "  Selected: $selectedWsName (RG: $selectedRgName, Sub: $($selectedSentinel.subscriptionName))" -ForegroundColor Green

#endregion

#region ── Step 5: List Sentinel Data Connectors ──────────────────────────────

Write-Host "`n[5/5] Retrieving Sentinel data connectors..." -ForegroundColor Green

$subId = $selectedSentinel.subscriptionId
$apiBase = "https://management.azure.com/subscriptions/$subId/resourceGroups/$selectedRgName/providers/Microsoft.OperationalInsights/workspaces/$selectedWsName/providers/Microsoft.SecurityInsights"
$apiVersion = "2025-09-01"

# ── Helper: paginated REST GET ──
function Get-AllPages {
    param([string]$Url)
    $all = @()
    $nextUrl = $Url
    while ($nextUrl) {
        $resp = az rest --method get --url $nextUrl -o json 2>$null | ConvertFrom-Json
        if ($resp) {
            $valProp = $resp.PSObject.Properties | Where-Object { $_.Name -eq 'value' }
            if ($valProp -and $valProp.Value) { $all += $valProp.Value }
            $nlProp = $resp.PSObject.Properties | Where-Object { $_.Name -eq 'nextLink' }
            $nextUrl = if ($nlProp -and $nlProp.Value) { $nlProp.Value } else { $null }
        } else { $nextUrl = $null }
    }
    return $all
}

# ── Helper: safely read a property from a PSObject ──
function Get-SafeProp {
    param($Obj, [string]$PropName, $Default = '')
    if (-not $Obj) { return $Default }
    $prop = $Obj.PSObject.Properties | Where-Object { $_.Name -eq $PropName }
    if ($prop -and $null -ne $prop.Value) { return $prop.Value }
    return $Default
}

# 1) Fetch explicit data connector resources (the directly configured ones)
Write-Host "  Fetching data connectors..." -ForegroundColor Gray
$dataConnectors = @(Get-AllPages "$apiBase/dataConnectors?api-version=$apiVersion")
Write-Host "    Data connector resources: $($dataConnectors.Count)" -ForegroundColor Gray

# 2) Fetch data connector definitions (Content Hub / codeless connectors with connectivity queries)
Write-Host "  Fetching data connector definitions..." -ForegroundColor Gray
$connectorDefs = @(Get-AllPages "$apiBase/dataConnectorDefinitions?api-version=$apiVersion")
Write-Host "    Connector definitions: $($connectorDefs.Count)" -ForegroundColor Gray

# 3) Fetch Data Collection Rules (DCRs) targeting this workspace via Resource Graph
Write-Host "  Fetching Data Collection Rules targeting this workspace..." -ForegroundColor Gray
$workspaceResourceId = "/subscriptions/$subId/resourceGroups/$selectedRgName/providers/Microsoft.OperationalInsights/workspaces/$selectedWsName"
$dcrQuery = @{
    query   = "resources | where type == 'microsoft.insights/datacollectionrules' | where properties.destinations.logAnalytics[0].workspaceResourceId =~ '$workspaceResourceId' or tostring(properties) contains '$selectedWsName' | project name, resourceGroup, subscriptionId, location, properties"
    options = @{ resultFormat = "objectArray" }
} | ConvertTo-Json -Compress -Depth 5

$dcrBodyFile = Join-Path $env:TEMP "sentinel_dcr_query.json"
Set-Content -Path $dcrBodyFile -Value $dcrQuery -Encoding UTF8
$dcrRaw = az rest --method post `
    --url "https://management.azure.com/providers/Microsoft.ResourceGraph/resources?api-version=2022-10-01" `
    --body "@$dcrBodyFile" `
    --query "data" -o json 2>$null
Remove-Item $dcrBodyFile -Force -ErrorAction SilentlyContinue

$dcrResults = @()
if ($dcrRaw) {
    $parsed = $dcrRaw | ConvertFrom-Json
    if ($parsed) {
        if ($parsed -isnot [System.Array]) { $parsed = @($parsed) }
        $dcrResults = $parsed
    }
}
Write-Host "    Data Collection Rules: $($dcrResults.Count)" -ForegroundColor Gray

# 5) Fetch Content Hub content templates of kind DataConnector / ResourcesDataConnector
#    These represent ALL connector pages shown in the Sentinel portal
Write-Host "  Fetching Content Hub connector templates..." -ForegroundColor Gray
$connectorTemplates = @(Get-AllPages "$apiBase/contentTemplates?api-version=$apiVersion")
$dcTemplates = @($connectorTemplates | Where-Object {
    $templateProps = Get-SafeProp $_ 'properties' $null
    if ($templateProps) {
        $ck = Get-SafeProp $templateProps 'contentKind' ''
        $ck -eq 'DataConnector' -or $ck -eq 'ResourcesDataConnector'
    } else { $false }
})
Write-Host "    Connector templates (from Content Hub): $($dcTemplates.Count)" -ForegroundColor Gray

# Build a lookup of explicit connectors by connectorDefinitionName (for cross-referencing)
$explicitByDefName = @{}
foreach ($dc in $dataConnectors) {
    $props = Get-SafeProp $dc 'properties' $null
    if ($props) {
        $defName = Get-SafeProp $props 'connectorDefinitionName' ''
        if ($defName) { $explicitByDefName[$defName] = $dc }
    }
}

# ── Migration complexity lookup ──
$complexityMap = @{
    'AzureActiveDirectory'              = @{ Complexity = 'Low';    Notes = 'Enable via portal toggle. Requires Entra ID P1/P2 license.' }
    'AzureAdvancedThreatProtection'     = @{ Complexity = 'Low';    Notes = 'Single toggle. Requires Defender for Identity license.' }
    'AzureSecurityCenter'               = @{ Complexity = 'Low';    Notes = 'Enable per subscription. Requires Defender for Cloud.' }
    'MicrosoftDefenderAdvancedThreatProtection' = @{ Complexity = 'Low'; Notes = 'Single toggle. Requires MDE license.' }
    'MicrosoftCloudAppSecurity'         = @{ Complexity = 'Low';    Notes = 'Single toggle. Requires Defender for Cloud Apps license.' }
    'Office365'                         = @{ Complexity = 'Low';    Notes = 'Enable per data type (Exchange, SharePoint, Teams). No extra license needed with M365.' }
    'OfficeATP'                         = @{ Complexity = 'Low';    Notes = 'Single toggle. Requires MDO P1/P2 license.' }
    'OfficeIRM'                         = @{ Complexity = 'Low';    Notes = 'Single toggle. Requires Azure Information Protection.' }
    'OfficePowerBI'                     = @{ Complexity = 'Low';    Notes = 'Single toggle. Requires Power BI Pro license.' }
    'Office365Project'                  = @{ Complexity = 'Low';    Notes = 'Single toggle. Requires Project Online license.' }
    'MicrosoftThreatIntelligence'       = @{ Complexity = 'Low';    Notes = 'Enable via portal. Free threat intel from Microsoft.' }
    'MicrosoftThreatProtection'         = @{ Complexity = 'Low';    Notes = 'Single toggle. Requires M365 Defender license.' }
    'MicrosoftPurviewInformationProtection' = @{ Complexity = 'Low'; Notes = 'Single toggle. Requires Purview Information Protection license.' }
    'Dynamics365'                       = @{ Complexity = 'Low';    Notes = 'Single toggle. Requires Dynamics 365 license.' }
    'AzureActivity'                     = @{ Complexity = 'Low';    Notes = 'Configured via Azure Policy. Re-assign diagnostic settings policy to new workspace.' }
    'AmazonWebServicesCloudTrail'       = @{ Complexity = 'High';   Notes = 'Requires AWS cross-account role, SQS queue, and S3 bucket configuration.' }
    'AmazonWebServicesS3'               = @{ Complexity = 'High';   Notes = 'Requires AWS IAM role, SQS, and S3 policy configuration.' }
    'GCP'                               = @{ Complexity = 'High';   Notes = 'Requires GCP project configuration, pub/sub, and workload identity federation.' }
    'GenericUI'                         = @{ Complexity = 'Medium'; Notes = 'Custom connector via Content Hub. Re-install solution and reconfigure.' }
    'APIPolling'                        = @{ Complexity = 'Medium'; Notes = 'Custom API polling connector. Requires API credentials and endpoint reconfiguration.' }
    'CodelessUI'                        = @{ Complexity = 'Medium'; Notes = 'Codeless connector. Re-install Content Hub solution.' }
    'Customizable'                      = @{ Complexity = 'Medium'; Notes = 'Content Hub codeless connector. Re-install solution and provide credentials.' }
    'RestApiPoller'                     = @{ Complexity = 'Medium'; Notes = 'REST API poller. Requires API credentials and endpoint reconfiguration.' }
    'Syslog'                            = @{ Complexity = 'Medium'; Notes = 'Requires AMA agent on forwarder, plus DCR configuration.' }
    'CEF'                               = @{ Complexity = 'Medium'; Notes = 'Requires AMA agent on forwarder, plus DCR and device-side syslog config.' }
    'ThreatIntelligence'                = @{ Complexity = 'Medium'; Notes = 'Requires TI platform integration or TAXII server reconfiguration.' }
    'ThreatIntelligenceTaxii'           = @{ Complexity = 'Medium'; Notes = 'Requires TAXII server URL, collection ID, and credentials.' }
    'WindowsSecurityEvents'             = @{ Complexity = 'Medium'; Notes = 'Requires AMA agent on endpoints and DCR for event filtering.' }
    'WindowsFirewall'                   = @{ Complexity = 'Medium'; Notes = 'Requires AMA agent and DCR on Windows endpoints.' }
    'DNS'                               = @{ Complexity = 'Medium'; Notes = 'Requires agent on DNS servers and DCR configuration.' }
    'IOT'                               = @{ Complexity = 'Medium'; Notes = 'Requires Defender for IoT sensor deployment and hub configuration.' }
    'SecurityEvents'                    = @{ Complexity = 'Medium'; Notes = 'Requires AMA or MMA agent on Windows endpoints with DCR.' }
}

# ── Build report from EXPLICIT data connectors ──
$report = @()

foreach ($c in $dataConnectors) {
    $kind = Get-SafeProp $c 'kind' 'Unknown'
    $props = Get-SafeProp $c 'properties' $null

    $dataTypeStates = ''
    if ($props) {
        $dtObj = Get-SafeProp $props 'dataTypes' $null
        if ($dtObj) {
            $stateParts = @()
            foreach ($dtProp in $dtObj.PSObject.Properties) {
                $stateVal = ''
                if ($dtProp.Value) { $stateVal = Get-SafeProp $dtProp.Value 'state' '' }
                if (-not $stateVal) { $stateVal = 'Unknown' }
                $stateParts += "$($dtProp.Name): $stateVal"
            }
            $dataTypeStates = $stateParts -join '; '
        }
    }

    $connTenantId = ''
    if ($props) { $connTenantId = Get-SafeProp $props 'tenantId' '' }

    $connName = Get-SafeProp $c 'name' ''
    $isConnected = ($dataTypeStates -match 'Enabled' -or $dataTypeStates -match 'enabled')

    # Check if this is a RestApiPoller with isActive flag
    if ($props) {
        $isActive = Get-SafeProp $props 'isActive' $null
        if ($null -ne $isActive -and $isActive -eq $true) { $isConnected = $true }
    }

    $lookup = $complexityMap[$kind]
    $complexity = if ($lookup) { $lookup.Complexity } else { 'Medium' }
    $notes      = if ($lookup) { $lookup.Notes }      else { 'Review connector configuration manually. May require credentials or agent setup.' }

    $report += [PSCustomObject]@{
        ConnectorName     = $connName
        Kind              = $kind
        Source            = 'DataConnector'
        Status            = if ($isConnected) { 'Connected' } else { 'Not Connected' }
        DataTypeStates    = $dataTypeStates
        ConnectorId       = $connName
        TenantId          = $connTenantId
        Complexity        = $complexity
        MigrationNotes    = $notes
        ResourceGroup     = $selectedRgName
        Workspace         = $selectedWsName
        Subscription      = $selectedSentinel.subscriptionName
        FullResourceId    = Get-SafeProp $c 'id' ''
    }
}

# ── Build report from CONNECTOR DEFINITIONS (Content Hub connectors) ──
$processedDefNames = @{}
foreach ($def in $connectorDefs) {
    $defName = Get-SafeProp $def 'name' ''
    if ($processedDefNames.ContainsKey($defName)) { continue }
    $processedDefNames[$defName] = $true

    $kind = Get-SafeProp $def 'kind' 'Unknown'
    $props = Get-SafeProp $def 'properties' $null
    $uiConfig = if ($props) { Get-SafeProp $props 'connectorUiConfig' $null } else { $null }

    $title = ''
    $publisher = ''
    $description = ''
    $dataTypeNames = @()

    if ($uiConfig) {
        $title     = Get-SafeProp $uiConfig 'title' ''
        $publisher = Get-SafeProp $uiConfig 'publisher' ''
        $description = Get-SafeProp $uiConfig 'descriptionMarkdown' ''
        # Truncate description for CSV
        if ($description.Length -gt 200) { $description = $description.Substring(0, 200) + '...' }

        # Get data type table names
        $dtArray = Get-SafeProp $uiConfig 'dataTypes' $null
        if ($dtArray -and $dtArray -is [System.Array]) {
            foreach ($dt in $dtArray) {
                $dtName = Get-SafeProp $dt 'name' ''
                if ($dtName) { $dataTypeNames += $dtName }
            }
        }
    }

    if (-not $title) { $title = $defName }

    # Check if there is an explicit data connector instance for this definition
    $hasInstance = $explicitByDefName.ContainsKey($defName)
    $status = if ($hasInstance) { 'Connected' } else { 'Installed' }

    $lookup = $complexityMap[$kind]
    $complexity = if ($lookup) { $lookup.Complexity } else { 'Medium' }
    $notes      = if ($lookup) { $lookup.Notes }      else { 'Content Hub connector. Re-install solution and configure credentials.' }

    $report += [PSCustomObject]@{
        ConnectorName     = $title
        Kind              = $kind
        Source            = 'ContentHub'
        Status            = $status
        DataTypeStates    = ($dataTypeNames -join '; ')
        ConnectorId       = $defName
        TenantId          = ''
        Complexity        = $complexity
        MigrationNotes    = "$notes Publisher: $publisher"
        ResourceGroup     = $selectedRgName
        Workspace         = $selectedWsName
        Subscription      = $selectedSentinel.subscriptionName
        FullResourceId    = Get-SafeProp $def 'id' ''
    }
}

# ── Build report from DATA COLLECTION RULES ──
foreach ($dcr in $dcrResults) {
    if (-not $dcr) { continue }
    $dcrName = Get-SafeProp $dcr 'name' ''
    $dcrRg   = Get-SafeProp $dcr 'resourceGroup' ''
    $dcrLoc  = Get-SafeProp $dcr 'location' ''
    $dcrProps = Get-SafeProp $dcr 'properties' $null

    # Extract stream names / data sources to identify what type of data is collected
    $streamNames = @()
    $dcrKind = 'DCR'
    if ($dcrProps) {
        # Check dataSources for known types
        $dataSources = Get-SafeProp $dcrProps 'dataSources' $null
        if ($dataSources) {
            $wse = Get-SafeProp $dataSources 'windowsEventLogs' $null
            if ($wse) { $streamNames += 'WindowsEventLogs'; $dcrKind = 'WindowsSecurityEvents (DCR)' }

            $syslog = Get-SafeProp $dataSources 'syslog' $null
            if ($syslog) { $streamNames += 'Syslog'; $dcrKind = 'Syslog (DCR)' }

            $perfCounters = Get-SafeProp $dataSources 'performanceCounters' $null
            if ($perfCounters) { $streamNames += 'PerformanceCounters' }

            $extensions = Get-SafeProp $dataSources 'extensions' $null
            if ($extensions) { $streamNames += 'Extensions' }

            $logFiles = Get-SafeProp $dataSources 'logFiles' $null
            if ($logFiles) { $streamNames += 'CustomLogs'; $dcrKind = 'Custom Logs (DCR)' }

            $iis = Get-SafeProp $dataSources 'iisLogs' $null
            if ($iis) { $streamNames += 'IISLogs'; $dcrKind = 'IIS Logs (DCR)' }
        }

        # Check dataFlows for stream details
        $dataFlows = Get-SafeProp $dcrProps 'dataFlows' $null
        if ($dataFlows -and $dataFlows -is [System.Array]) {
            foreach ($flow in $dataFlows) {
                $streams = Get-SafeProp $flow 'streams' $null
                if ($streams -and $streams -is [System.Array]) {
                    $streamNames += $streams
                }
                $outputStream = Get-SafeProp $flow 'outputStream' ''
                if ($outputStream) { $streamNames += $outputStream }
            }
        }
    }
    $streamNames = @($streamNames | Select-Object -Unique)

    $report += [PSCustomObject]@{
        ConnectorName     = $dcrName
        Kind              = $dcrKind
        Source            = 'DataCollectionRule'
        Status            = 'Connected'
        DataTypeStates    = ($streamNames -join '; ')
        ConnectorId       = $dcrName
        TenantId          = ''
        Complexity        = 'Medium'
        MigrationNotes    = "DCR in RG: $dcrRg, Location: $dcrLoc. Recreate DCR and reassign to agents/resources in new workspace."
        ResourceGroup     = $dcrRg
        Workspace         = $selectedWsName
        Subscription      = $selectedSentinel.subscriptionName
        FullResourceId    = ''
    }
}

# ── Build report from CONTENT HUB CONNECTOR TEMPLATES ──
# These are the connector pages visible in the Sentinel portal from installed solutions.
# Only add ones not already covered by explicit data connectors or connector definitions.
$existingNames = @{}
foreach ($r in $report) { $existingNames[$r.ConnectorName] = $true }

foreach ($tmpl in $dcTemplates) {
    $tmplProps = Get-SafeProp $tmpl 'properties' $null
    if (-not $tmplProps) { continue }

    $displayName = Get-SafeProp $tmplProps 'displayName' ''
    if (-not $displayName) { $displayName = Get-SafeProp $tmpl 'name' '' }

    # Skip if already in report by name
    if ($existingNames.ContainsKey($displayName)) { continue }

    $contentKind = Get-SafeProp $tmplProps 'contentKind' ''
    $sourceObj   = Get-SafeProp $tmplProps 'source' $null
    $sourceKind  = if ($sourceObj) { Get-SafeProp $sourceObj 'kind' '' } else { '' }
    $sourceName  = if ($sourceObj) { Get-SafeProp $sourceObj 'name' '' } else { '' }

    # Determine status: if it has contentId that matches an explicit connector, it's Connected
    $contentId   = Get-SafeProp $tmplProps 'contentId' ''
    $isConnected = $false
    foreach ($dc in $dataConnectors) {
        $dcKind = Get-SafeProp $dc 'kind' ''
        if ($dcKind -and $displayName -match [regex]::Escape($dcKind)) { $isConnected = $true; break }
    }

    $existingNames[$displayName] = $true

    $lookup = $complexityMap.Keys | Where-Object { $displayName -match [regex]::Escape($_) } | Select-Object -First 1
    $complexity = 'Medium'
    $notes = "Content Hub solution connector. Install '$sourceName' solution and configure."
    if ($lookup) {
        $complexity = $complexityMap[$lookup].Complexity
        $notes = $complexityMap[$lookup].Notes
    }

    $report += [PSCustomObject]@{
        ConnectorName     = $displayName
        Kind              = $contentKind
        Source            = 'ContentHubTemplate'
        Status            = if ($isConnected) { 'Connected' } else { 'Installed' }
        DataTypeStates    = ''
        ConnectorId       = $contentId
        TenantId          = ''
        Complexity        = $complexity
        MigrationNotes    = $notes
        ResourceGroup     = $selectedRgName
        Workspace         = $selectedWsName
        Subscription      = $selectedSentinel.subscriptionName
        FullResourceId    = Get-SafeProp $tmpl 'id' ''
    }
}

if ($report.Count -eq 0) {
    Write-Host "`n  No data connectors found in workspace '$selectedWsName'." -ForegroundColor Yellow
    exit 0
}

Write-Host "`n  Total connectors found: $($report.Count)`n" -ForegroundColor Green

# ── Display summary table ──
$report | Sort-Object Source, Status, Kind | Format-Table ConnectorName, Kind, Source, Status, DataTypeStates, Complexity -AutoSize -Wrap

# ── Export CSV for migration assessment ──
$csvPath = Join-Path $PSScriptRoot "SentinelConnectors_${selectedWsName}_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
$report | Sort-Object Source, Status, Kind | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
Write-Host "  CSV exported: $csvPath" -ForegroundColor Green

# ── Print migration summary ──
$connectedCount    = @($report | Where-Object { $_.Status -eq 'Connected' }).Count
$installedCount    = @($report | Where-Object { $_.Status -eq 'Installed' }).Count
$notConnectedCount = @($report | Where-Object { $_.Status -eq 'Not Connected' }).Count
$dcCount           = @($report | Where-Object { $_.Source -eq 'DataConnector' }).Count
$chCount           = @($report | Where-Object { $_.Source -eq 'ContentHub' }).Count
$chtCount          = @($report | Where-Object { $_.Source -eq 'ContentHubTemplate' }).Count
$dcrCount          = @($report | Where-Object { $_.Source -eq 'DataCollectionRule' }).Count
$grouped = $report | Group-Object Complexity

Write-Host ""
Write-Host "  ============================================================" -ForegroundColor Cyan
Write-Host "    Migration Assessment Summary" -ForegroundColor Cyan
Write-Host "  ============================================================" -ForegroundColor Cyan
Write-Host "    Data Connector resources:    $dcCount" -ForegroundColor White
Write-Host "    Content Hub definitions:     $chCount" -ForegroundColor White
Write-Host "    Content Hub templates:       $chtCount" -ForegroundColor White
Write-Host "    Data Collection Rules:       $dcrCount" -ForegroundColor White
Write-Host ""
Write-Host "    Connected:       $connectedCount" -ForegroundColor Green
Write-Host "    Installed:       $installedCount (definition present, needs configuration)" -ForegroundColor Yellow
Write-Host "    Not Connected:   $notConnectedCount" -ForegroundColor Gray
Write-Host ""
Write-Host "    Migration Complexity:" -ForegroundColor White
foreach ($g in $grouped | Sort-Object Name) {
    $color = switch ($g.Name) { 'Low' { 'Green' } 'Medium' { 'Yellow' } 'High' { 'Red' } default { 'White' } }
    Write-Host "      $($g.Name): $($g.Count)" -ForegroundColor $color
}
Write-Host "    Total: $($report.Count)" -ForegroundColor White
Write-Host ""

Write-Host "`nDone." -ForegroundColor Green

#endregion
