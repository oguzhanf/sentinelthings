#Requires -Modules Az.Accounts, Az.Resources, Az.OperationalInsights, Az.LogicApp
<#
.SYNOPSIS
    Deploys the complete Microsoft 365 Copilot audit log ingestion solution to Microsoft Sentinel.

.DESCRIPTION
    This script automates the complete deployment of the Copilot audit log ingestion solution including:
    1. Creating the custom table in Microsoft Sentinel
    2. Deploying the Logic App using ARM template
    3. Configuring authentication and permissions
    4. Validating the deployment

.PARAMETER SubscriptionId
    Azure Subscription ID

.PARAMETER ResourceGroupName
    Resource Group name for deployment

.PARAMETER WorkspaceName
    Log Analytics workspace name (Sentinel workspace)

.PARAMETER Location
    Azure region for deployment (default: East US)

.PARAMETER LogicAppName
    Name of the Logic App (default: copilot-audit-ingestion)

.PARAMETER RecurrenceFrequency
    Frequency for the Logic App trigger (default: Hour)

.PARAMETER RecurrenceInterval
    Interval for the Logic App trigger (default: 1)

.PARAMETER DeploymentMode
    ARM deployment mode (default: Incremental)

.PARAMETER SkipTableCreation
    Skip custom table creation if it already exists

.PARAMETER SkipAuthentication
    Skip authentication setup

.PARAMETER ValidateOnly
    Only validate the deployment without executing

.EXAMPLE
    .\Deploy-CopilotAuditSolution.ps1 -SubscriptionId "your-sub-id" -ResourceGroupName "rg-sentinel" -WorkspaceName "law-sentinel"

.EXAMPLE
    .\Deploy-CopilotAuditSolution.ps1 -SubscriptionId "your-sub-id" -ResourceGroupName "rg-sentinel" -WorkspaceName "law-sentinel" -ValidateOnly
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$SubscriptionId,
    
    [Parameter(Mandatory = $true)]
    [string]$ResourceGroupName,
    
    [Parameter(Mandatory = $true)]
    [string]$WorkspaceName,
    
    [Parameter(Mandatory = $false)]
    [string]$Location = "East US",
    
    [Parameter(Mandatory = $false)]
    [string]$LogicAppName = "copilot-audit-ingestion",
    
    [Parameter(Mandatory = $false)]
    [ValidateSet("Minute", "Hour", "Day")]
    [string]$RecurrenceFrequency = "Hour",
    
    [Parameter(Mandatory = $false)]
    [int]$RecurrenceInterval = 1,
    
    [Parameter(Mandatory = $false)]
    [ValidateSet("Incremental", "Complete")]
    [string]$DeploymentMode = "Incremental",
    
    [Parameter(Mandatory = $false)]
    [switch]$SkipTableCreation,
    
    [Parameter(Mandatory = $false)]
    [switch]$SkipAuthentication,
    
    [Parameter(Mandatory = $false)]
    [switch]$ValidateOnly
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
    $requiredModules = @('Az.Accounts', 'Az.Resources', 'Az.OperationalInsights', 'Az.LogicApp')
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

# Function to validate parameters
function Test-DeploymentParameters {
    Write-ColorOutput "Validating deployment parameters..." "Yellow"
    
    # Validate subscription
    try {
        $subscription = Get-AzSubscription -SubscriptionId $SubscriptionId -ErrorAction Stop
        Write-ColorOutput "Subscription validated: $($subscription.Name)" "Green"
    } catch {
        throw "Invalid subscription ID: $SubscriptionId"
    }
    
    # Validate resource group
    $resourceGroup = Get-AzResourceGroup -Name $ResourceGroupName -ErrorAction SilentlyContinue
    if (-not $resourceGroup) {
        Write-ColorOutput "Resource group '$ResourceGroupName' not found. Creating..." "Yellow"
        $resourceGroup = New-AzResourceGroup -Name $ResourceGroupName -Location $Location
        Write-ColorOutput "Resource group created successfully" "Green"
    } else {
        Write-ColorOutput "Resource group validated: $ResourceGroupName" "Green"
    }
    
    # Validate workspace
    $workspace = Get-AzOperationalInsightsWorkspace -ResourceGroupName $ResourceGroupName -Name $WorkspaceName -ErrorAction SilentlyContinue
    if (-not $workspace) {
        throw "Log Analytics workspace '$WorkspaceName' not found in resource group '$ResourceGroupName'"
    }
    Write-ColorOutput "Workspace validated: $WorkspaceName" "Green"
    
    return @{
        ResourceGroup = $resourceGroup
        Workspace = $workspace
    }
}

# Function to create custom table
function New-CopilotAuditTable {
    param($Workspace)
    
    if ($SkipTableCreation) {
        Write-ColorOutput "Skipping table creation as requested" "Yellow"
        return
    }
    
    Write-ColorOutput "Creating custom table: copilotauditlogs_cl" "Yellow"
    
    $scriptPath = Join-Path $PSScriptRoot "Create-CopilotAuditTable.ps1"
    if (-not (Test-Path $scriptPath)) {
        throw "Create-CopilotAuditTable.ps1 not found in script directory"
    }
    
    & $scriptPath -SubscriptionId $SubscriptionId -ResourceGroupName $ResourceGroupName -WorkspaceName $WorkspaceName
    
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to create custom table"
    }
    
    Write-ColorOutput "Custom table created successfully" "Green"
}

# Function to deploy Logic App
function Deploy-LogicApp {
    param($Workspace)
    
    Write-ColorOutput "Deploying Logic App: $LogicAppName" "Yellow"
    
    $templatePath = Join-Path $PSScriptRoot "infrastructure\arm-template.json"
    if (-not (Test-Path $templatePath)) {
        throw "ARM template not found: $templatePath"
    }
    
    # Get workspace key
    $workspaceKey = (Get-AzOperationalInsightsWorkspaceSharedKey -ResourceGroupName $ResourceGroupName -Name $WorkspaceName).PrimarySharedKey
    
    $templateParameters = @{
        logicAppName = $LogicAppName
        location = $Location
        tenantId = (Get-AzContext).Tenant.Id
        workspaceResourceId = $Workspace.ResourceId
        workspaceId = $Workspace.CustomerId
        workspaceKey = $workspaceKey
        recurrenceFrequency = $RecurrenceFrequency
        recurrenceInterval = $RecurrenceInterval
    }
    
    $deploymentName = "CopilotAuditSolution-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
    
    if ($ValidateOnly) {
        Write-ColorOutput "Validating ARM template deployment..." "Yellow"
        $validation = Test-AzResourceGroupDeployment -ResourceGroupName $ResourceGroupName -TemplateFile $templatePath -TemplateParameterObject $templateParameters
        
        if ($validation) {
            Write-ColorOutput "Template validation failed:" "Red"
            $validation | ForEach-Object { Write-ColorOutput "  - $($_.Message)" "Red" }
            throw "Template validation failed"
        } else {
            Write-ColorOutput "Template validation successful" "Green"
            return
        }
    }
    
    $deployment = New-AzResourceGroupDeployment -ResourceGroupName $ResourceGroupName -Name $deploymentName -TemplateFile $templatePath -TemplateParameterObject $templateParameters -Mode $DeploymentMode -Verbose
    
    if ($deployment.ProvisioningState -eq "Succeeded") {
        Write-ColorOutput "Logic App deployed successfully" "Green"
        return $deployment.Outputs
    } else {
        throw "Logic App deployment failed: $($deployment.ProvisioningState)"
    }
}

# Function to configure authentication
function Set-Authentication {
    param($DeploymentOutputs, $Workspace)
    
    if ($SkipAuthentication) {
        Write-ColorOutput "Skipping authentication setup as requested" "Yellow"
        return
    }
    
    Write-ColorOutput "Configuring authentication and permissions..." "Yellow"
    
    $scriptPath = Join-Path $PSScriptRoot "Setup-Authentication.ps1"
    if (-not (Test-Path $scriptPath)) {
        throw "Setup-Authentication.ps1 not found in script directory"
    }
    
    & $scriptPath -SubscriptionId $SubscriptionId -ResourceGroupName $ResourceGroupName -LogicAppName $LogicAppName -WorkspaceResourceId $Workspace.ResourceId
    
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to configure authentication"
    }
    
    Write-ColorOutput "Authentication configured successfully" "Green"
}

# Main script execution
try {
    Write-ColorOutput "=== Microsoft 365 Copilot Audit Log Ingestion Solution Deployment ===" "Cyan"
    Write-ColorOutput "Starting deployment process..." "Green"
    
    # Check and install required modules
    Write-ColorOutput "Checking required PowerShell modules..." "Yellow"
    Test-RequiredModules
    
    # Connect to Azure
    Write-ColorOutput "Connecting to Azure..." "Yellow"
    Connect-AzAccount -UseDeviceAuthentication -SubscriptionId $SubscriptionId
    Set-AzContext -SubscriptionId $SubscriptionId
    Write-ColorOutput "Connected to subscription: $SubscriptionId" "Green"
    
    # Validate parameters
    $validationResults = Test-DeploymentParameters
    
    # Create custom table
    New-CopilotAuditTable -Workspace $validationResults.Workspace
    
    # Deploy Logic App
    $deploymentOutputs = Deploy-LogicApp -Workspace $validationResults.Workspace
    
    if (-not $ValidateOnly) {
        # Configure authentication
        Set-Authentication -DeploymentOutputs $deploymentOutputs -Workspace $validationResults.Workspace
        
        Write-ColorOutput "`n=== Deployment Summary ===" "Cyan"
        Write-ColorOutput "Subscription ID: $SubscriptionId" "White"
        Write-ColorOutput "Resource Group: $ResourceGroupName" "White"
        Write-ColorOutput "Workspace: $WorkspaceName" "White"
        Write-ColorOutput "Logic App: $LogicAppName" "White"
        Write-ColorOutput "Location: $Location" "White"
        Write-ColorOutput "Recurrence: Every $RecurrenceInterval $RecurrenceFrequency" "White"
        Write-ColorOutput "Status: Deployed Successfully" "Green"
        
        if ($deploymentOutputs) {
            Write-ColorOutput "`nDeployment Outputs:" "Yellow"
            $deploymentOutputs.Keys | ForEach-Object {
                Write-ColorOutput "  $($_): $($deploymentOutputs[$_].Value)" "White"
            }
        }
        
        Write-ColorOutput "`nNext Steps:" "Yellow"
        Write-ColorOutput "1. Verify the Logic App is running in Azure Portal" "White"
        Write-ColorOutput "2. Check the custom table 'copilotauditlogs_cl' in Sentinel" "White"
        Write-ColorOutput "3. Monitor Logic App runs for any errors" "White"
        Write-ColorOutput "4. Test data ingestion after Copilot activities occur" "White"
        Write-ColorOutput "`nQuery to check ingested data:" "Cyan"
        Write-ColorOutput "copilotauditlogs_cl | take 10" "White"
    }
    
} catch {
    Write-ColorOutput "Error occurred: $($_.Exception.Message)" "Red"
    Write-ColorOutput "Stack trace: $($_.ScriptStackTrace)" "Red"
    exit 1
}
