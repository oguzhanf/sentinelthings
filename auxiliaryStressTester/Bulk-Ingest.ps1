# Bulk Data Ingestion for Microsoft Sentinel Cost Testing
param(
    [string]$SubscriptionId = "YOUR_SUBSCRIPTION_ID_HERE",
    [string]$ResourceGroupName = "YOUR_RESOURCE_GROUP_NAME",
    [string]$WorkspaceName = "YOUR_WORKSPACE_NAME",
    [string]$TableName = "AuxiliaryTestData_CL",
    [int]$TotalRecords = 100000,
    [int]$BatchSize = 1000
)

Write-Host "=== Bulk Data Ingestion for Cost Testing ===" -ForegroundColor Cyan
Write-Host "Target Records: $TotalRecords" -ForegroundColor Yellow
Write-Host "Batch Size: $BatchSize" -ForegroundColor Yellow
Write-Host "Estimated Data Size: $([math]::Round(($TotalRecords * 2048) / 1GB, 2)) GB" -ForegroundColor Yellow

# Check authentication
$context = Get-AzContext
if (!$context -or $context.Subscription.Id -ne $SubscriptionId) {
    Write-Host "Connecting to Azure..." -ForegroundColor Yellow
    Connect-AzAccount -UseDeviceAuthentication -SubscriptionId $SubscriptionId
}

# Get workspace details
$workspace = Get-AzOperationalInsightsWorkspace -ResourceGroupName $ResourceGroupName -Name $WorkspaceName
$workspaceId = $workspace.CustomerId
$workspaceKey = (Get-AzOperationalInsightsWorkspaceSharedKey -ResourceGroupName $ResourceGroupName -Name $WorkspaceName).PrimarySharedKey

Write-Host "Workspace ID: $workspaceId" -ForegroundColor Green

# Function to generate bulk test data
function Generate-TestData {
    param([int]$Count, [int]$StartIndex = 0)
    
    $data = @()
    $eventTypes = @("Login", "Logout", "FileAccess", "NetworkConnection", "SystemAlert", "DataExport", "ConfigChange", "SecurityScan", "EmailAccess", "DatabaseQuery", "APICall", "FileUpload", "FileDownload", "UserCreated", "UserDeleted", "PasswordChange", "PermissionChange", "VPNConnect", "VPNDisconnect", "PrintJob")
    $users = @("john.doe", "jane.smith", "bob.wilson", "alice.brown", "charlie.davis", "david.jones", "emma.taylor", "frank.miller", "grace.lee", "henry.clark", "ivy.martinez", "jack.rodriguez", "kelly.garcia", "liam.anderson", "mia.thomas", "noah.jackson", "olivia.white", "paul.harris", "quinn.martin", "ruby.thompson")
    $sources = @("WebApp", "MobileApp", "Desktop", "API", "Service", "Database", "FileServer", "EmailSystem", "VPN", "Firewall", "Proxy", "LoadBalancer", "CloudService", "Container", "VM", "Kubernetes", "Docker", "Jenkins", "GitLab", "SharePoint")
    $countries = @("US", "UK", "DE", "FR", "JP", "AU", "CA", "BR", "IN", "CN", "RU", "IT", "ES", "NL", "SE", "NO", "DK", "FI", "PL", "CZ")
    $devices = @("Windows-Desktop", "MacOS-Laptop", "iPhone", "Android", "iPad", "Linux-Server", "Windows-Server", "Ubuntu-Desktop", "CentOS-Server", "Docker-Container")
    
    for ($i = 0; $i -lt $Count; $i++) {
        $currentIndex = $StartIndex + $i
        $baseTime = (Get-Date).AddMinutes(-($currentIndex % 10080))
        
        $eventType = $eventTypes | Get-Random
        $user = $users | Get-Random
        $source = $sources | Get-Random
        $success = (Get-Random -Minimum 0 -Maximum 10) -gt 1
        $severity = if ($success) { Get-Random -Minimum 1 -Maximum 3 } else { Get-Random -Minimum 3 -Maximum 5 }
        
        $ipOctet1 = if ((Get-Random -Minimum 0 -Maximum 10) -gt 7) { Get-Random -Minimum 1 -Maximum 255 } else { @(192, 10, 172)[(Get-Random -Minimum 0 -Maximum 3)] }
        $ipAddress = "$ipOctet1.$(Get-Random -Minimum 1 -Maximum 255).$(Get-Random -Minimum 1 -Maximum 255).$(Get-Random -Minimum 1 -Maximum 255)"
        
        $data += [PSCustomObject]@{
            TimeGenerated = $baseTime.ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
            EventType = $eventType
            UserName = $user
            SourceSystem = $source
            EventId = [System.Guid]::NewGuid().ToString()
            Severity = $severity
            Message = "Bulk test event $currentIndex - $eventType by $user from $source - $(Get-Random -Minimum 1000 -Maximum 9999)"
            IPAddress = $ipAddress
            Success = $success
            Country = $countries | Get-Random
            Device = $devices | Get-Random
            SessionId = [System.Guid]::NewGuid().ToString().Substring(0, 8)
            BytesTransferred = Get-Random -Minimum 100 -Maximum 1048576
            Duration = Get-Random -Minimum 1 -Maximum 3600
            UserAgent = "TestAgent/1.0 (Bulk-$currentIndex)"
            Protocol = @("HTTPS", "HTTP", "SSH", "FTP", "SMTP", "DNS", "LDAP")[(Get-Random -Minimum 0 -Maximum 7)]
            Port = @(80, 443, 22, 21, 25, 53, 389, 3389, 5432, 3306)[(Get-Random -Minimum 0 -Maximum 10)]
            ResponseCode = if ($success) { @(200, 201, 202)[(Get-Random -Minimum 0 -Maximum 3)] } else { @(400, 401, 403, 404, 500, 502, 503)[(Get-Random -Minimum 0 -Maximum 7)] }
        }
    }
    
    return $data
}

# Function to send data to Log Analytics
function Send-DataBatch {
    param([string]$WorkspaceId, [string]$WorkspaceKey, [string]$LogType, [string]$JsonData, [int]$BatchNum)
    
    try {
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
        
        Invoke-RestMethod -Uri $uri -Method $method -ContentType $contentType -Headers $headers -Body $JsonData | Out-Null
        Write-Host "Batch $BatchNum uploaded successfully - Size: $([math]::Round($contentLength/1MB, 2)) MB" -ForegroundColor Green
        return $true
    }
    catch {
        Write-Host "Batch $BatchNum failed: $($_.Exception.Message)" -ForegroundColor Red
        return $false
    }
}

# Main ingestion loop
$totalBatches = [math]::Ceiling($TotalRecords / $BatchSize)
$startTime = Get-Date
$successCount = 0

Write-Host "Starting ingestion of $totalBatches batches..." -ForegroundColor Yellow

for ($batch = 0; $batch -lt $totalBatches; $batch++) {
    $batchNumber = $batch + 1
    $startIndex = $batch * $BatchSize
    $recordsInBatch = [math]::Min($BatchSize, $TotalRecords - $startIndex)
    
    Write-Host "Processing batch $batchNumber of $totalBatches - $recordsInBatch records" -ForegroundColor Cyan
    
    # Generate data
    $batchData = Generate-TestData -Count $recordsInBatch -StartIndex $startIndex
    $jsonData = $batchData | ConvertTo-Json -Depth 3 -Compress
    
    # Send data
    $success = Send-DataBatch -WorkspaceId $workspaceId -WorkspaceKey $workspaceKey -LogType $TableName.Replace("_CL", "") -JsonData $jsonData -BatchNum $batchNumber
    
    if ($success) {
        $successCount++
    }
    
    # Progress update
    $progress = [math]::Round(($batchNumber / $totalBatches) * 100, 1)
    Write-Host "Progress: $progress% - $batchNumber of $totalBatches batches completed" -ForegroundColor Yellow
    
    # Small delay to avoid rate limiting
    Start-Sleep -Milliseconds 200
}

$endTime = Get-Date
$duration = $endTime - $startTime

Write-Host "`n=== Ingestion Summary ===" -ForegroundColor Cyan
Write-Host "Total Records: $TotalRecords" -ForegroundColor White
Write-Host "Successful Batches: $successCount of $totalBatches" -ForegroundColor Green
Write-Host "Duration: $($duration.ToString('hh\:mm\:ss'))" -ForegroundColor White
Write-Host "Rate: $([math]::Round($TotalRecords / $duration.TotalSeconds, 0)) records/second" -ForegroundColor Cyan
Write-Host "Estimated Data Size: $([math]::Round(($TotalRecords * 2048) / 1GB, 2)) GB" -ForegroundColor Yellow
Write-Host "Estimated Cost: $([math]::Round((($TotalRecords * 2048) / 1GB) * 2.76, 2)) USD" -ForegroundColor Red

Write-Host "`nData will be available for querying in 5-10 minutes" -ForegroundColor Yellow
