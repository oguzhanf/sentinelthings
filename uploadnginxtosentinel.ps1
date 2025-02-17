
# Posts a csv file as data into a custom log table
# Define your workspace ID and primary key
$workspaceId = ""
$workspaceKey = ""
$logType = "customLogTable_CL"  # Custom log table name; '_CL' is appended automatically

# Path to your CSV file
$filePath = "file.csv"

# Import the CSV file and convert to JSON
$csvData = Import-Csv -Path $filePath
$jsonData = $csvData | ConvertTo-Json -Depth 3

# Convert JSON to bytes (the API expects a UTF-8 encoded JSON payload)
$bytes = [System.Text.Encoding]::UTF8.GetBytes($jsonData)
$contentLength = $bytes.Length

# Function to build the authorization header using a here-string
function Get-AuthorizationHeader {
    param (
        [string]$workspaceId,
        [string]$workspaceKey,
        [string]$date,
        [int]$contentLength
    )
    $stringToHash = @"
POST
$contentLength
application/json
x-ms-date:$date
/api/logs
"@
    # Replace CRLF with LF, which the API expects
    $stringToHash = $stringToHash -replace "`r`n", "`n"
    $bytesToHash = [System.Text.Encoding]::UTF8.GetBytes($stringToHash)
    $keyBytes = [Convert]::FromBase64String($workspaceKey)
    $sha256 = New-Object System.Security.Cryptography.HMACSHA256
    $sha256.Key = $keyBytes
    $hashedBytes = $sha256.ComputeHash($bytesToHash)
    $signature = [Convert]::ToBase64String($hashedBytes)
    return "SharedKey ${workspaceId}:$signature"
}

# Prepare the request parameters
$date = [DateTime]::UtcNow.ToString("r")
$authorizationHeader = Get-AuthorizationHeader -workspaceId $workspaceId -workspaceKey $workspaceKey -date $date -contentLength $contentLength

# Define the API endpoint
$apiUrl = "https://${workspaceId}.ods.opinsights.azure.com/api/logs?api-version=2016-04-01"

# Create the HTTP request
$httpRequest = [System.Net.HttpWebRequest]::Create($apiUrl)
$httpRequest.Method = "POST"
$httpRequest.ContentType = "application/json"
$httpRequest.Headers.Add("Authorization", $authorizationHeader)
$httpRequest.Headers.Add("x-ms-date", $date)
$httpRequest.Headers.Add("Log-Type", $logType)
$httpRequest.ContentLength = $bytes.Length

# Write the content to the request stream
$requestStream = $httpRequest.GetRequestStream()
try {
    $requestStream.Write($bytes, 0, $bytes.Length)
}
finally {
    $requestStream.Close()
}

# Send the request and get the response
try {
    $response = $httpRequest.GetResponse()
    $response
    Write-Host "Data successfully posted to Azure Sentinel."
}
catch {
    Write-Host "Failed to post data: $_"
}
