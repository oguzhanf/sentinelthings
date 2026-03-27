#Requires -Modules Az.Accounts, Az.Resources, Az.OperationalInsights, Az.Monitor
<#
.SYNOPSIS
    Creates an auxiliary table in Microsoft Sentinel and ingests test data.

.DESCRIPTION
    This script automates the process of:
    1. Connecting to Azure
    2. Setting up Log Analytics workspace (if needed)
    3. Creating a custom auxiliary table in Microsoft Sentinel
    4. Ingesting test data into the table

.PARAMETER SubscriptionId
    Azure Subscription ID

.PARAMETER ResourceGroupName
    Resource Group name for the Log Analytics workspace

.PARAMETER WorkspaceName
    Log Analytics workspace name

.PARAMETER Location
    Azure region for resources (default: East US)

.PARAMETER TableName
    Name of the auxiliary table to create (default: AuxiliaryTestData_CL)

.EXAMPLE
    .\Setup-SentinelAuxiliaryTable.ps1 -SubscriptionId "your-sub-id" -ResourceGroupName "rg-sentinel" -WorkspaceName "law-sentinel"
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
    [string]$TableName = "AuxiliaryTestData_CL"
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
    $requiredModules = @('Az.Accounts', 'Az.Resources', 'Az.OperationalInsights', 'Az.Monitor')
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

# Function to create test data
function Get-TestData {
    $testData = @()
    $eventTypes = @("Login", "Logout", "FileAccess", "NetworkConnection", "SystemAlert")
    $users = @("john.doe", "jane.smith", "bob.wilson", "alice.brown", "charlie.davis")
    $sources = @("WebApp", "MobileApp", "Desktop", "API", "Service")
    
    for ($i = 1; $i -le 50; $i++) {
        $testData += [PSCustomObject]@{
            TimeGenerated = (Get-Date).AddMinutes(-$i).ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
            EventType = $eventTypes | Get-Random
            UserName = $users | Get-Random
            SourceSystem = $sources | Get-Random
            EventId = [System.Guid]::NewGuid().ToString()
            Severity = Get-Random -Minimum 1 -Maximum 5
            Message = "Test event $i - $(Get-Random -Minimum 1000 -Maximum 9999)"
            IPAddress = "192.168.$(Get-Random -Minimum 1 -Maximum 255).$(Get-Random -Minimum 1 -Maximum 255)"
            Success = (Get-Random -Minimum 0 -Maximum 2) -eq 1
        }
    }
    
    return $testData
}

# Main script execution
try {
    Write-ColorOutput "=== Microsoft Sentinel Auxiliary Table Setup ===" "Cyan"
    Write-ColorOutput "Starting setup process..." "Green"
    
    # Check and install required modules
    Write-ColorOutput "Checking required PowerShell modules..." "Yellow"
    Test-RequiredModules
    
    # Connect to Azure using device code flow
    Write-ColorOutput "Connecting to Azure using device code flow..." "Yellow"
    Write-ColorOutput "This will open a browser window for one-time authentication..." "Cyan"
    Connect-AzAccount -UseDeviceAuthentication -SubscriptionId $SubscriptionId
    
    # Set context
    Set-AzContext -SubscriptionId $SubscriptionId
    Write-ColorOutput "Connected to subscription: $SubscriptionId" "Green"
    
    # Check if resource group exists, create if not
    Write-ColorOutput "Checking resource group: $ResourceGroupName" "Yellow"
    $rg = Get-AzResourceGroup -Name $ResourceGroupName -ErrorAction SilentlyContinue
    if (!$rg) {
        Write-ColorOutput "Creating resource group: $ResourceGroupName" "Yellow"
        New-AzResourceGroup -Name $ResourceGroupName -Location $Location
        Write-ColorOutput "Resource group created successfully" "Green"
    } else {
        Write-ColorOutput "Resource group already exists" "Green"
    }
    
    # Check if Log Analytics workspace exists, create if not
    Write-ColorOutput "Checking Log Analytics workspace: $WorkspaceName" "Yellow"
    $workspace = Get-AzOperationalInsightsWorkspace -ResourceGroupName $ResourceGroupName -Name $WorkspaceName -ErrorAction SilentlyContinue
    if (!$workspace) {
        Write-ColorOutput "Creating Log Analytics workspace: $WorkspaceName" "Yellow"
        $workspace = New-AzOperationalInsightsWorkspace -ResourceGroupName $ResourceGroupName -Name $WorkspaceName -Location $Location -Sku "PerGB2018"
        Write-ColorOutput "Log Analytics workspace created successfully" "Green"
        
        # Wait for workspace to be fully provisioned
        Write-ColorOutput "Waiting for workspace provisioning..." "Yellow"
        Start-Sleep -Seconds 60
    } else {
        Write-ColorOutput "Log Analytics workspace already exists" "Green"
    }
    
    # Get workspace details
    $workspaceId = $workspace.CustomerId
    $workspaceKey = (Get-AzOperationalInsightsWorkspaceSharedKey -ResourceGroupName $ResourceGroupName -Name $WorkspaceName).PrimarySharedKey
    
    Write-ColorOutput "Workspace ID: $workspaceId" "Cyan"
    
    # Generate test data
    Write-ColorOutput "Generating test data..." "Yellow"
    $testData = Get-TestData
    Write-ColorOutput "Generated $($testData.Count) test records" "Green"
    
    # Convert test data to JSON
    $jsonData = $testData | ConvertTo-Json -Depth 3
    
    # Create the HTTP Data Collector API function
    Write-ColorOutput "Preparing data ingestion..." "Yellow"
    
    # Function to send data to Log Analytics
    function Send-LogAnalyticsData {
        param(
            [string]$WorkspaceId,
            [string]$WorkspaceKey,
            [string]$LogType,
            [string]$JsonData
        )
        
        $method = "POST"
        $contentType = "application/json"
        $resource = "/api/logs"
        $rfc1123date = [DateTime]::UtcNow.ToString("r")
        $contentLength = [System.Text.Encoding]::UTF8.GetBytes($JsonData).Length
        
        $xHeaders = "x-ms-date:" + $rfc1123date
        $stringToHash = $method + "`n" + $contentLength + "`n" + $contentType + "`n" + $xHeaders + "`n" + $resource
        
        $bytesToHash = [Text.Encoding]::UTF8.GetBytes($stringToHash)
        $keyBytes = [Convert]::FromBase64String($WorkspaceKey)
        
        $sha256 = New-Object System.Security.Cryptography.HMACSHA256
        $sha256.Key = $keyBytes
        $calculatedHash = $sha256.ComputeHash($bytesToHash)
        $encodedHash = [Convert]::ToBase64String($calculatedHash)
        $authorization = 'SharedKey {0}:{1}' -f $WorkspaceId, $encodedHash
        
        $uri = "https://" + $WorkspaceId + ".ods.opinsights.azure.com" + $resource + "?api-version=2016-04-01"
        
        $headers = @{
            "Authorization"        = $authorization
            "Log-Type"            = $LogType
            "x-ms-date"           = $rfc1123date
            "time-generated-field" = "TimeGenerated"
        }
        
        try {
            $response = Invoke-RestMethod -Uri $uri -Method $method -ContentType $contentType -Headers $headers -Body $JsonData
            return $true
        }
        catch {
            Write-Error "Failed to send data: $($_.Exception.Message)"
            return $false
        }
    }
    
    # Send data to Log Analytics
    Write-ColorOutput "Ingesting test data into table: $TableName" "Yellow"
    $success = Send-LogAnalyticsData -WorkspaceId $workspaceId -WorkspaceKey $workspaceKey -LogType $TableName.Replace("_CL", "") -JsonData $jsonData
    
    if ($success) {
        Write-ColorOutput "Data ingestion completed successfully!" "Green"
        Write-ColorOutput "Note: It may take 5-10 minutes for data to appear in the workspace" "Yellow"
    } else {
        Write-ColorOutput "Data ingestion failed!" "Red"
        exit 1
    }
    
    # Output summary
    Write-ColorOutput "`n=== Setup Summary ===" "Cyan"
    Write-ColorOutput "Resource Group: $ResourceGroupName" "White"
    Write-ColorOutput "Workspace Name: $WorkspaceName" "White"
    Write-ColorOutput "Workspace ID: $workspaceId" "White"
    Write-ColorOutput "Table Name: $TableName" "White"
    Write-ColorOutput "Records Ingested: $($testData.Count)" "White"
    Write-ColorOutput "`nYou can query the data using KQL in Log Analytics or Sentinel:" "Yellow"
    Write-ColorOutput "$TableName | take 10" "Cyan"
    
}
catch {
    Write-ColorOutput "Error occurred: $($_.Exception.Message)" "Red"
    Write-ColorOutput "Stack trace: $($_.ScriptStackTrace)" "Red"
    exit 1
}
