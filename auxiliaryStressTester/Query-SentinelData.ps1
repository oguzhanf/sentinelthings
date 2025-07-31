#Requires -Modules Az.Accounts, Az.OperationalInsights
<#
.SYNOPSIS
    Queries data from the auxiliary table in Microsoft Sentinel.

.DESCRIPTION
    This script provides utilities to query and validate the data ingested into the auxiliary table.

.PARAMETER SubscriptionId
    Azure Subscription ID

.PARAMETER ResourceGroupName
    Resource Group name for the Log Analytics workspace

.PARAMETER WorkspaceName
    Log Analytics workspace name

.PARAMETER TableName
    Name of the auxiliary table to query (default: AuxiliaryTestData_CL)

.PARAMETER Query
    Custom KQL query to execute

.EXAMPLE
    .\Query-SentinelData.ps1 -SubscriptionId "your-sub-id" -ResourceGroupName "rg-sentinel" -WorkspaceName "law-sentinel"
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$SubscriptionId,
    
    [Parameter(Mandatory = $true)]
    [string]$ResourceGroupName,
    
    [Parameter(Mandatory = $true)]
    [string]$WorkspaceName,
    
    [Parameter(Mandatory = $false)]
    [string]$TableName = "AuxiliaryTestData_CL",
    
    [Parameter(Mandatory = $false)]
    [string]$Query = ""
)

# Function to write colored output
function Write-ColorOutput {
    param(
        [string]$Message,
        [string]$Color = "White"
    )
    Write-Host $Message -ForegroundColor $Color
}

# Predefined queries
$predefinedQueries = @{
    "count" = "$TableName | count"
    "recent" = "$TableName | where TimeGenerated > ago(1h) | take 10"
    "summary" = "$TableName | summarize Count=count() by EventType | order by Count desc"
    "users" = "$TableName | summarize Count=count() by UserName | order by Count desc"
    "errors" = "$TableName | where Success == false | take 20"
    "timeline" = "$TableName | summarize Count=count() by bin(TimeGenerated, 5m) | order by TimeGenerated desc"
}

try {
    Write-ColorOutput "=== Microsoft Sentinel Data Query Tool ===" "Cyan"
    
    # Check if already authenticated
    $context = Get-AzContext
    if (!$context -or $context.Subscription.Id -ne $SubscriptionId) {
        # Connect to Azure using device code flow
        Write-ColorOutput "Connecting to Azure using device code flow..." "Yellow"
        Write-ColorOutput "This will open a browser window for one-time authentication..." "Cyan"
        Connect-AzAccount -UseDeviceAuthentication -SubscriptionId $SubscriptionId
    } else {
        Write-ColorOutput "Already authenticated to Azure" "Green"
    }
    Set-AzContext -SubscriptionId $SubscriptionId
    
    # Get workspace
    $workspace = Get-AzOperationalInsightsWorkspace -ResourceGroupName $ResourceGroupName -Name $WorkspaceName
    if (!$workspace) {
        Write-ColorOutput "Workspace not found!" "Red"
        exit 1
    }
    
    Write-ColorOutput "Connected to workspace: $WorkspaceName" "Green"
    
    if ($Query -eq "") {
        # Show menu of predefined queries
        Write-ColorOutput "`nAvailable predefined queries:" "Yellow"
        $predefinedQueries.Keys | ForEach-Object { Write-ColorOutput "  $_" "Cyan" }
        
        $selection = Read-Host "`nEnter query name (or 'custom' for custom query)"
        
        if ($selection -eq "custom") {
            $Query = Read-Host "Enter your KQL query"
        } elseif ($predefinedQueries.ContainsKey($selection)) {
            $Query = $predefinedQueries[$selection]
        } else {
            Write-ColorOutput "Invalid selection. Using count query." "Yellow"
            $Query = $predefinedQueries["count"]
        }
    }
    
    Write-ColorOutput "`nExecuting query: $Query" "Yellow"
    
    # Execute query
    $result = Invoke-AzOperationalInsightsQuery -WorkspaceId $workspace.CustomerId -Query $Query
    
    if ($result.Results) {
        Write-ColorOutput "`nQuery Results:" "Green"
        $result.Results | Format-Table -AutoSize
        Write-ColorOutput "Total rows returned: $($result.Results.Count)" "Cyan"
    } else {
        Write-ColorOutput "No results returned. Data might still be ingesting (can take 5-10 minutes)." "Yellow"
    }
    
}
catch {
    Write-ColorOutput "Error occurred: $($_.Exception.Message)" "Red"
    exit 1
}
