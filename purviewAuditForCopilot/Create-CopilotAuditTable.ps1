#Requires -Modules Az.Accounts, Az.Resources, Az.OperationalInsights
<#
.SYNOPSIS
    Creates a custom table for Microsoft 365 Copilot audit logs in Microsoft Sentinel.

.DESCRIPTION
    This script creates the 'copilotauditlogs_cl' custom table in Microsoft Sentinel
    with the appropriate schema for storing Microsoft 365 Copilot audit activities.
    The table schema is designed to capture all relevant Copilot audit data including
    user activities, content interactions, and system events.

.PARAMETER SubscriptionId
    Azure Subscription ID where the Sentinel workspace is located

.PARAMETER ResourceGroupName
    Resource Group name containing the Log Analytics workspace

.PARAMETER WorkspaceName
    Log Analytics workspace name (Sentinel workspace)

.PARAMETER TableName
    Name of the custom table to create (default: copilotauditlogs_cl)

.PARAMETER RetentionDays
    Data retention period in days (default: 365)

.EXAMPLE
    .\Create-CopilotAuditTable.ps1 -SubscriptionId "your-sub-id" -ResourceGroupName "rg-sentinel" -WorkspaceName "law-sentinel"

.EXAMPLE
    .\Create-CopilotAuditTable.ps1 -SubscriptionId "your-sub-id" -ResourceGroupName "rg-sentinel" -WorkspaceName "law-sentinel" -RetentionDays 730
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$SubscriptionId,
    
    [Parameter(Mandatory = $true)]
    [string]$ResourceGroupName,
    
    [Parameter(Mandatory = $true)]
    [string]$WorkspaceName,
    
    [Parameter(Mandatory = $false)]
    [string]$TableName = "copilotauditlogs_cl",
    
    [Parameter(Mandatory = $false)]
    [int]$RetentionDays = 365
)

# Function to write colored output
function Write-ColorOutput {
    param(
        [string]$Message,
        [string]$Color = "White"
    )
    Write-Host $Message -ForegroundColor $Color
}

# Function to check if required modules are installed
function Test-RequiredModules {
    $requiredModules = @('Az.Accounts', 'Az.Resources', 'Az.OperationalInsights')
    $missingModules = @()
    
    foreach ($module in $requiredModules) {
        if (!(Get-Module -ListAvailable -Name $module)) {
            $missingModules += $module
        }
    }
    
    if ($missingModules.Count -gt 0) {
        Write-ColorOutput "Missing required modules: $($missingModules -join ', ')" "Red"
        Write-ColorOutput "Installing missing modules..." "Yellow"
        
        foreach ($module in $missingModules) {
            Install-Module -Name $module -Force -AllowClobber -Scope CurrentUser
        }
    }
}

# Main script execution
try {
    Write-ColorOutput "=== Microsoft 365 Copilot Audit Table Creation ===" "Cyan"
    Write-ColorOutput "Creating custom table: $TableName" "Green"
    
    # Check and install required modules
    Write-ColorOutput "Checking required PowerShell modules..." "Yellow"
    Test-RequiredModules
    
    # Connect to Azure
    Write-ColorOutput "Connecting to Azure..." "Yellow"
    Connect-AzAccount -UseDeviceAuthentication -SubscriptionId $SubscriptionId
    Set-AzContext -SubscriptionId $SubscriptionId
    Write-ColorOutput "Connected to subscription: $SubscriptionId" "Green"
    
    # Validate workspace exists
    Write-ColorOutput "Validating Log Analytics workspace..." "Yellow"
    $workspace = Get-AzOperationalInsightsWorkspace -ResourceGroupName $ResourceGroupName -Name $WorkspaceName -ErrorAction SilentlyContinue
    if (!$workspace) {
        throw "Log Analytics workspace '$WorkspaceName' not found in resource group '$ResourceGroupName'"
    }
    Write-ColorOutput "Workspace validated successfully" "Green"
    
    # Define the table schema for Copilot audit logs
    $tableSchema = @{
        name = $TableName
        columns = @(
            @{ name = "TimeGenerated"; type = "datetime" }
            @{ name = "ActivityId"; type = "string" }
            @{ name = "ActivityType"; type = "string" }
            @{ name = "UserId"; type = "string" }
            @{ name = "UserPrincipalName"; type = "string" }
            @{ name = "ClientIP"; type = "string" }
            @{ name = "UserAgent"; type = "string" }
            @{ name = "AppName"; type = "string" }
            @{ name = "AppId"; type = "string" }
            @{ name = "CopilotEventType"; type = "string" }
            @{ name = "ContentType"; type = "string" }
            @{ name = "ContentId"; type = "string" }
            @{ name = "ContentName"; type = "string" }
            @{ name = "ContentUrl"; type = "string" }
            @{ name = "QueryText"; type = "string" }
            @{ name = "ResponseText"; type = "string" }
            @{ name = "TokensUsed"; type = "int" }
            @{ name = "SessionId"; type = "string" }
            @{ name = "ConversationId"; type = "string" }
            @{ name = "TenantId"; type = "string" }
            @{ name = "OrganizationId"; type = "string" }
            @{ name = "ResultStatus"; type = "string" }
            @{ name = "ErrorCode"; type = "string" }
            @{ name = "ErrorMessage"; type = "string" }
            @{ name = "SourceSystem"; type = "string" }
            @{ name = "AdditionalProperties"; type = "dynamic" }
        )
    }
    
    # Create the payload for table creation
    $payload = @{
        properties = @{
            schema = $tableSchema
            totalRetentionInDays = $RetentionDays
            plan = "Analytics"
        }
    } | ConvertTo-Json -Depth 10
    
    # Construct the REST API URI
    $uri = "/subscriptions/$SubscriptionId/resourcegroups/$ResourceGroupName/providers/microsoft.operationalinsights/workspaces/$WorkspaceName/tables/$TableName" + "?api-version=2023-01-01-preview"
    
    Write-ColorOutput "Creating custom table with schema..." "Yellow"
    Write-ColorOutput "Table: $TableName" "Cyan"
    Write-ColorOutput "Retention: $RetentionDays days" "Cyan"
    Write-ColorOutput "Columns: $($tableSchema.columns.Count)" "Cyan"
    
    # Create the table using REST API
    $response = Invoke-AzRestMethod -Path $uri -Method PUT -Payload $payload
    
    if ($response.StatusCode -eq 200 -or $response.StatusCode -eq 201) {
        Write-ColorOutput "Custom table created successfully!" "Green"
        
        # Parse response to get table details
        $responseContent = $response.Content | ConvertFrom-Json
        
        Write-ColorOutput "`n=== Table Creation Summary ===" "Cyan"
        Write-ColorOutput "Subscription ID: $SubscriptionId" "White"
        Write-ColorOutput "Resource Group: $ResourceGroupName" "White"
        Write-ColorOutput "Workspace: $WorkspaceName" "White"
        Write-ColorOutput "Table Name: $TableName" "White"
        Write-ColorOutput "Retention Days: $RetentionDays" "White"
        Write-ColorOutput "Plan: Analytics" "White"
        Write-ColorOutput "Status: Created" "Green"
        
        Write-ColorOutput "`nTable Schema Columns:" "Yellow"
        foreach ($column in $tableSchema.columns) {
            Write-ColorOutput "  - $($column.name) ($($column.type))" "White"
        }
        
        Write-ColorOutput "`nNext Steps:" "Yellow"
        Write-ColorOutput "1. Deploy the Logic App to start ingesting Copilot audit data" "White"
        Write-ColorOutput "2. Configure authentication and permissions" "White"
        Write-ColorOutput "3. Test data ingestion" "White"
        Write-ColorOutput "`nQuery the table in Sentinel using: $TableName | take 10" "Cyan"
        
    } else {
        Write-ColorOutput "Failed to create table. Status Code: $($response.StatusCode)" "Red"
        Write-ColorOutput "Response: $($response.Content)" "Red"
        exit 1
    }
    
} catch {
    Write-ColorOutput "Error occurred: $($_.Exception.Message)" "Red"
    Write-ColorOutput "Stack trace: $($_.ScriptStackTrace)" "Red"
    exit 1
}
