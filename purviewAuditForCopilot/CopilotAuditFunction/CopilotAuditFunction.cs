using Microsoft.Azure.Functions.Worker;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Configuration;
using System.Text.Json;
using System.Net.Http.Headers;
using System.Text;
using System.Security.Cryptography;

namespace CopilotAuditFunction;

public class CopilotAuditFunction
{
    private readonly ILogger<CopilotAuditFunction> _logger;
    private readonly IConfiguration _config;
    private readonly HttpClient _httpClient;
    private string? _cachedToken;
    private DateTime _tokenExpiry = DateTime.MinValue;

    public CopilotAuditFunction(ILogger<CopilotAuditFunction> logger, IConfiguration config, HttpClient httpClient)
    {
        _logger = logger;
        _config = config;
        _httpClient = httpClient;
    }

    [Function("ProcessCopilotAuditLogs")]
    public async Task ProcessCopilotAuditLogs([TimerTrigger("%TimerSchedule%")] TimerInfo timer)
    {
        _logger.LogInformation("Timer trigger function executed at: {time}", DateTime.Now);
        
        var startTime = DateTime.UtcNow.AddHours(-int.Parse(_config["LookbackHours"] ?? "1"));
        var endTime = DateTime.UtcNow;
        
        _logger.LogInformation("Starting Copilot audit log processing for period: {start} to {end}", startTime, endTime);

        try
        {
            var token = await GetAccessTokenAsync();
            await EnsureSubscriptionAsync(token);
            var contentBlobs = await GetAvailableContentAsync(token, startTime, endTime);
            
            var allRecords = new List<JsonElement>();
            foreach (var blob in contentBlobs)
            {
                var records = await GetAuditRecordsAsync(token, blob.GetProperty("contentUri").GetString()!);
                allRecords.AddRange(records);
            }

            var copilotRecords = allRecords.Where(r => IsCopilotRecord(r)).ToList();
            _logger.LogInformation("Filtered {count} Copilot records from {total} total records", copilotRecords.Count, allRecords.Count);

            if (copilotRecords.Any())
            {
                await SendToSentinelAsync(copilotRecords);
            }

            _logger.LogInformation("Successfully processed {count} Copilot audit records", copilotRecords.Count);
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Critical error during processing: {message}", ex.Message);
            throw;
        }

        _logger.LogInformation("Next timer schedule at: {nextRun}", timer.ScheduleStatus?.Next);
    }

    private async Task<string> GetAccessTokenAsync()
    {
        if (!string.IsNullOrEmpty(_cachedToken) && DateTime.UtcNow < _tokenExpiry)
            return _cachedToken;

        var tokenUrl = $"https://login.microsoftonline.com/{_config["TenantId"]}/oauth2/v2.0/token";
        var requestBody = new List<KeyValuePair<string, string>>
        {
            new("client_id", _config["ClientId"]!),
            new("client_secret", _config["ClientSecret"]!),
            new("scope", "https://manage.office.com/.default"),
            new("grant_type", "client_credentials")
        };

        var response = await _httpClient.PostAsync(tokenUrl, new FormUrlEncodedContent(requestBody));
        var content = await response.Content.ReadAsStringAsync();

        if (!response.IsSuccessStatusCode)
        {
            _logger.LogError("Failed to acquire access token. Status: {status}, Response: {response}", response.StatusCode, content);
            throw new HttpRequestException($"Failed to acquire access token: {response.StatusCode}");
        }

        var authResponse = JsonSerializer.Deserialize<JsonElement>(content);
        _cachedToken = authResponse.GetProperty("access_token").GetString()!;
        var expiresIn = authResponse.GetProperty("expires_in").GetInt32();
        _tokenExpiry = DateTime.UtcNow.AddSeconds(expiresIn - 300);

        return _cachedToken;
    }

    private async Task EnsureSubscriptionAsync(string token)
    {
        var subscriptionUrl = $"{_config["Office365ManagementApiBaseUrl"]}/{_config["TenantId"]}/activity/feed/subscriptions/start?contentType=Audit.General";

        var request = new HttpRequestMessage(HttpMethod.Post, subscriptionUrl);
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);

        var response = await _httpClient.SendAsync(request);
        var content = await response.Content.ReadAsStringAsync();

        if (response.IsSuccessStatusCode)
        {
            _logger.LogInformation("Subscription ensured successfully for Audit.General content type");
        }
        else if (response.StatusCode == System.Net.HttpStatusCode.BadRequest && content.Contains("already enabled"))
        {
            _logger.LogInformation("Subscription already enabled for Audit.General content type");
        }
        else
        {
            _logger.LogError("Failed to ensure subscription. Status: {status}, Response: {response}", response.StatusCode, content);
        }
    }

    private async Task<List<JsonElement>> GetAvailableContentAsync(string token, DateTime startTime, DateTime endTime)
    {
        var startTimeFormatted = startTime.ToString("yyyy-MM-ddTHH:mm:ss.fffZ");
        var endTimeFormatted = endTime.ToString("yyyy-MM-ddTHH:mm:ss.fffZ");

        var contentUrl = $"{_config["Office365ManagementApiBaseUrl"]}/{_config["TenantId"]}/activity/feed/subscriptions/content" +
                        $"?contentType=Audit.General&startTime={startTimeFormatted}&endTime={endTimeFormatted}";

        var request = new HttpRequestMessage(HttpMethod.Get, contentUrl);
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);

        var response = await _httpClient.SendAsync(request);
        var content = await response.Content.ReadAsStringAsync();

        if (!response.IsSuccessStatusCode)
        {
            _logger.LogError("Failed to get available content. Status: {status}, Response: {response}", response.StatusCode, content);
            return new List<JsonElement>();
        }

        var contentList = JsonSerializer.Deserialize<List<JsonElement>>(content) ?? new List<JsonElement>();
        _logger.LogInformation("Found {count} content blobs to process from Audit.General", contentList.Count);
        return contentList;
    }

    private async Task<List<JsonElement>> GetAuditRecordsAsync(string token, string contentUri)
    {
        var request = new HttpRequestMessage(HttpMethod.Get, contentUri);
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);

        var response = await _httpClient.SendAsync(request);
        var content = await response.Content.ReadAsStringAsync();

        if (!response.IsSuccessStatusCode)
        {
            _logger.LogError("Failed to get audit records from {uri}. Status: {status}", contentUri, response.StatusCode);
            return new List<JsonElement>();
        }

        return JsonSerializer.Deserialize<List<JsonElement>>(content) ?? new List<JsonElement>();
    }

    private bool IsCopilotRecord(JsonElement record)
    {
        try
        {
            // Check for Copilot-specific properties based on official schema
            // RecordType 261 = CopilotInteraction
            if (record.TryGetProperty("RecordType", out var recordType) && recordType.GetInt32() == 261)
            {
                return true;
            }

            // Check for Operation = "CopilotInteraction"
            if (record.TryGetProperty("Operation", out var operation) &&
                operation.GetString()?.Equals("CopilotInteraction", StringComparison.OrdinalIgnoreCase) == true)
            {
                return true;
            }

            // Check for Workload = "Copilot"
            if (record.TryGetProperty("Workload", out var workload) &&
                workload.GetString()?.Equals("Copilot", StringComparison.OrdinalIgnoreCase) == true)
            {
                return true;
            }

            // Fallback to string-based matching for additional coverage
            var recordJson = JsonSerializer.Serialize(record);
            return recordJson.Contains("copilot", StringComparison.OrdinalIgnoreCase) ||
                   recordJson.Contains("microsoft365copilot", StringComparison.OrdinalIgnoreCase) ||
                   recordJson.Contains("CopilotEventData", StringComparison.OrdinalIgnoreCase);
        }
        catch (Exception ex)
        {
            _logger.LogWarning(ex, "Error checking if record is Copilot record, falling back to string matching");
            var recordJson = JsonSerializer.Serialize(record);
            return recordJson.Contains("copilot", StringComparison.OrdinalIgnoreCase);
        }
    }

    private async Task SendToSentinelAsync(List<JsonElement> records)
    {
        var workspaceId = _config["WorkspaceId"]!;
        var workspaceKey = _config["WorkspaceKey"]!;
        var tableName = _config["CustomTableName"] ?? "CopilotAuditLogs_CL";

        var json = JsonSerializer.Serialize(records);
        var jsonBytes = Encoding.UTF8.GetBytes(json);

        var dateString = DateTime.UtcNow.ToString("r");
        var stringToHash = $"POST\n{jsonBytes.Length}\napplication/json\nx-ms-date:{dateString}\n/api/logs";
        var hashedString = Convert.ToBase64String(new HMACSHA256(Convert.FromBase64String(workspaceKey)).ComputeHash(Encoding.UTF8.GetBytes(stringToHash)));
        var signature = $"SharedKey {workspaceId}:{hashedString}";

        var url = $"https://{workspaceId}.ods.opinsights.azure.com/api/logs?api-version=2016-04-01";
        
        var request = new HttpRequestMessage(HttpMethod.Post, url);
        request.Headers.Add("Authorization", signature);
        request.Headers.Add("Log-Type", tableName.Replace("_CL", ""));
        request.Headers.Add("x-ms-date", dateString);
        request.Content = new ByteArrayContent(jsonBytes);
        request.Content.Headers.ContentType = new MediaTypeHeaderValue("application/json");

        var response = await _httpClient.SendAsync(request);
        
        if (response.IsSuccessStatusCode)
        {
            _logger.LogInformation("Successfully sent {count} records to Sentinel table {table}", records.Count, tableName);
        }
        else
        {
            var errorContent = await response.Content.ReadAsStringAsync();
            _logger.LogError("Failed to send data to Sentinel. Status: {status}, Response: {response}", response.StatusCode, errorContent);
        }
    }


}
