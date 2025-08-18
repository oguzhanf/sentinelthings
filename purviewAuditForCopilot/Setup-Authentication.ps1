#Requires -Modules Az.Accounts, Az.Resources, Az.Profile, Microsoft.Graph.Authentication, Microsoft.Graph.Applications
<#
.SYNOPSIS
    Configures authentication and permissions for the Copilot audit log ingestion Logic App.

.DESCRIPTION
    This script sets up the necessary authentication and permissions for the Logic App to:
    1. Access Microsoft 365 audit logs via the Office 365 Management API
    2. Write data to the Microsoft Sentinel workspace
    3. Configure managed identity permissions and API access

.PARAMETER SubscriptionId
    Azure Subscription ID

.PARAMETER ResourceGroupName
    Resource Group name containing the Logic App

.PARAMETER LogicAppName
    Name of the Logic App

.PARAMETER WorkspaceResourceId
    Resource ID of the Log Analytics workspace (Sentinel)

.PARAMETER TenantId
    Azure AD Tenant ID (defaults to current tenant)

.EXAMPLE
    .\Setup-Authentication.ps1 -SubscriptionId "your-sub-id" -ResourceGroupName "rg-sentinel" -LogicAppName "copilot-audit-ingestion" -WorkspaceResourceId "/subscriptions/sub-id/resourceGroups/rg-sentinel/providers/Microsoft.OperationalInsights/workspaces/law-sentinel"
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$SubscriptionId,
    
    [Parameter(Mandatory = $true)]
    [string]$ResourceGroupName,
    
    [Parameter(Mandatory = $true)]
    [string]$LogicAppName,
    
    [Parameter(Mandatory = $true)]
    [string]$WorkspaceResourceId,
    
    [Parameter(Mandatory = $false)]
    [string]$TenantId
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
    $requiredModules = @(
        'Az.Accounts', 
        'Az.Resources', 
        'Az.Profile',
        'Microsoft.Graph.Authentication',
        'Microsoft.Graph.Applications'
    )
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
    Write-ColorOutput "=== Copilot Audit Log Ingestion Authentication Setup ===" "Cyan"
    Write-ColorOutput "Configuring authentication and permissions..." "Green"
    
    # Check and install required modules
    Write-ColorOutput "Checking required PowerShell modules..." "Yellow"
    Test-RequiredModules
    
    # Connect to Azure
    Write-ColorOutput "Connecting to Azure..." "Yellow"
    Connect-AzAccount -UseDeviceAuthentication -SubscriptionId $SubscriptionId
    Set-AzContext -SubscriptionId $SubscriptionId
    
    # Get current tenant if not provided
    if (-not $TenantId) {
        $TenantId = (Get-AzContext).Tenant.Id
        Write-ColorOutput "Using current tenant: $TenantId" "Cyan"
    }
    
    Write-ColorOutput "Connected to subscription: $SubscriptionId" "Green"
    
    # Get Logic App details
    Write-ColorOutput "Retrieving Logic App details..." "Yellow"
    $logicApp = Get-AzResource -ResourceGroupName $ResourceGroupName -Name $LogicAppName -ResourceType "Microsoft.Logic/workflows"
    
    if (-not $logicApp) {
        throw "Logic App '$LogicAppName' not found in resource group '$ResourceGroupName'"
    }
    
    # Check if Logic App has managed identity
    $logicAppDetails = Get-AzLogicApp -ResourceGroupName $ResourceGroupName -Name $LogicAppName
    if (-not $logicAppDetails.Identity -or $logicAppDetails.Identity.Type -ne "SystemAssigned") {
        Write-ColorOutput "Enabling system-assigned managed identity for Logic App..." "Yellow"
        
        # Enable managed identity
        $identityPayload = @{
            identity = @{
                type = "SystemAssigned"
            }
        } | ConvertTo-Json -Depth 3
        
        $uri = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Logic/workflows/$LogicAppName" + "?api-version=2019-05-01"
        $response = Invoke-AzRestMethod -Path $uri -Method PATCH -Payload $identityPayload
        
        if ($response.StatusCode -eq 200) {
            Write-ColorOutput "Managed identity enabled successfully" "Green"
            Start-Sleep -Seconds 30  # Wait for identity to propagate
            $logicAppDetails = Get-AzLogicApp -ResourceGroupName $ResourceGroupName -Name $LogicAppName
        } else {
            throw "Failed to enable managed identity. Status: $($response.StatusCode)"
        }
    }
    
    $principalId = $logicAppDetails.Identity.PrincipalId
    Write-ColorOutput "Logic App Principal ID: $principalId" "Cyan"
    
    # Configure Log Analytics workspace permissions
    Write-ColorOutput "Configuring Log Analytics workspace permissions..." "Yellow"
    $workspaceResourceGroup = ($WorkspaceResourceId -split '/')[4]
    $workspaceName = ($WorkspaceResourceId -split '/')[-1]
    
    # Assign Log Analytics Contributor role
    $roleDefinitionId = "92aaf0da-9dab-42b6-94a3-d43ce8d16293"  # Log Analytics Contributor
    
    try {
        $existingAssignment = Get-AzRoleAssignment -ObjectId $principalId -RoleDefinitionId $roleDefinitionId -Scope $WorkspaceResourceId -ErrorAction SilentlyContinue
        
        if (-not $existingAssignment) {
            New-AzRoleAssignment -ObjectId $principalId -RoleDefinitionId $roleDefinitionId -Scope $WorkspaceResourceId
            Write-ColorOutput "Log Analytics Contributor role assigned successfully" "Green"
        } else {
            Write-ColorOutput "Log Analytics Contributor role already assigned" "Yellow"
        }
    } catch {
        Write-ColorOutput "Warning: Could not assign Log Analytics Contributor role. You may need to assign this manually." "Yellow"
        Write-ColorOutput "Principal ID: $principalId" "Cyan"
        Write-ColorOutput "Workspace Resource ID: $WorkspaceResourceId" "Cyan"
    }
    
    # Connect to Microsoft Graph for API permissions
    Write-ColorOutput "Connecting to Microsoft Graph..." "Yellow"
    Connect-MgGraph -Scopes "Application.ReadWrite.All", "AppRoleAssignment.ReadWrite.All" -TenantId $TenantId
    
    # Get Office 365 Management API service principal
    Write-ColorOutput "Configuring Office 365 Management API permissions..." "Yellow"
    $office365ManagementApi = Get-MgServicePrincipal -Filter "appId eq 'c5393580-f805-4401-95e8-94b7a6ef2fc2'" -ErrorAction SilentlyContinue
    
    if (-not $office365ManagementApi) {
        Write-ColorOutput "Office 365 Management API service principal not found. Creating..." "Yellow"
        # This might require admin consent in some tenants
        Write-ColorOutput "You may need to manually register the Office 365 Management API in your tenant" "Yellow"
    } else {
        Write-ColorOutput "Office 365 Management API service principal found" "Green"
    }
    
    # Get the Logic App's service principal
    $logicAppServicePrincipal = Get-MgServicePrincipal -Filter "displayName eq '$LogicAppName'" -ErrorAction SilentlyContinue
    
    if (-not $logicAppServicePrincipal) {
        Write-ColorOutput "Logic App service principal not found. This is expected for managed identities." "Yellow"
        Write-ColorOutput "Manual configuration may be required for Office 365 Management API access." "Yellow"
    }
    
    Write-ColorOutput "`n=== Authentication Setup Summary ===" "Cyan"
    Write-ColorOutput "Subscription ID: $SubscriptionId" "White"
    Write-ColorOutput "Resource Group: $ResourceGroupName" "White"
    Write-ColorOutput "Logic App: $LogicAppName" "White"
    Write-ColorOutput "Principal ID: $principalId" "White"
    Write-ColorOutput "Tenant ID: $TenantId" "White"
    Write-ColorOutput "Workspace Resource ID: $WorkspaceResourceId" "White"
    
    Write-ColorOutput "`nNext Steps:" "Yellow"
    Write-ColorOutput "1. Verify Log Analytics Contributor role assignment in Azure Portal" "White"
    Write-ColorOutput "2. Configure Office 365 Management API permissions manually if needed:" "White"
    Write-ColorOutput "   - Go to Azure AD > Enterprise Applications" "White"
    Write-ColorOutput "   - Find your Logic App managed identity" "White"
    Write-ColorOutput "   - Add API permissions for Office 365 Management APIs" "White"
    Write-ColorOutput "   - Grant admin consent for the permissions" "White"
    Write-ColorOutput "3. Test the Logic App workflow" "White"
    
    Write-ColorOutput "`nRequired API Permissions:" "Yellow"
    Write-ColorOutput "- ActivityFeed.Read (Office 365 Management APIs)" "White"
    Write-ColorOutput "- ActivityFeed.ReadDlp (Office 365 Management APIs)" "White"
    Write-ColorOutput "- ServiceHealth.Read (Office 365 Management APIs)" "White"
    
} catch {
    Write-ColorOutput "Error occurred: $($_.Exception.Message)" "Red"
    Write-ColorOutput "Stack trace: $($_.ScriptStackTrace)" "Red"
    exit 1
} finally {
    # Disconnect from Graph
    try {
        Disconnect-MgGraph -ErrorAction SilentlyContinue
    } catch {
        # Ignore disconnect errors
    }
}
