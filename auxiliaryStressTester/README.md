# Microsoft Sentinel Auxiliary Table Setup

This PowerShell automation suite helps you create auxiliary tables in Microsoft Sentinel and ingest test data for demonstration and testing purposes.

## Files Included

- `Setup-SentinelAuxiliaryTable.ps1` - Main script to create workspace and ingest initial data
- `Bulk-Ingest.ps1` - High-volume data ingestion script for cost testing
- `Query-SentinelData.ps1` - Utility script to query the ingested data
- `Connect-Azure.ps1` - Authentication helper with device code flow
- `config.json` - Configuration file with your Azure settings
- `README.md` - This documentation file

## Prerequisites

1. **Azure Subscription** with appropriate permissions
2. **PowerShell 5.1 or later**
3. **Azure PowerShell modules** (will be auto-installed if missing):
   - Az.Accounts
   - Az.Resources
   - Az.OperationalInsights
   - Az.Monitor

## Required Permissions

Your Azure account needs the following permissions:
- **Contributor** role on the subscription or resource group
- **Log Analytics Contributor** role for workspace operations
- **Microsoft Sentinel Contributor** role (if using Sentinel features)

## Quick Start

### 1. Configure Settings

Edit the `config.json` file with your Azure details:

```json
{
    "subscriptionId": "your-subscription-id-here",
    "resourceGroupName": "rg-sentinel-demo",
    "workspaceName": "law-sentinel-demo",
    "location": "East US",
    "tableName": "AuxiliaryTestData_CL"
}
```

### 2. Authenticate to Azure (One-time)

```powershell
.\Connect-Azure.ps1 -SubscriptionId "your-subscription-id"
```

### 3. Run the Setup Script

```powershell
# Basic setup with initial data
.\Setup-SentinelAuxiliaryTable.ps1 -SubscriptionId "your-sub-id" -ResourceGroupName "rg-sentinel" -WorkspaceName "law-sentinel"
```

### 4. Bulk Data Ingestion (for cost testing)

```powershell
# Medium volume test (100K records, ~0.2 GB)
.\Bulk-Ingest.ps1 -TotalRecords 100000

# Large volume test (500K records, ~1 GB)
.\Bulk-Ingest.ps1 -TotalRecords 500000

# Maximum volume test (5M records, ~10 GB)
.\Bulk-Ingest.ps1 -TotalRecords 5000000
```

### 5. Query the Data

```powershell
# Query with predefined options
.\Query-SentinelData.ps1 -SubscriptionId "your-sub-id" -ResourceGroupName "rg-sentinel" -WorkspaceName "law-sentinel"

# Custom query
.\Query-SentinelData.ps1 -SubscriptionId "your-sub-id" -ResourceGroupName "rg-sentinel" -WorkspaceName "law-sentinel" -Query "AuxiliaryTestData_CL | where EventType_s == 'Login' | take 5"
```

## What the Script Does

1. **Checks and installs** required PowerShell modules
2. **Authenticates** to Azure using your credentials
3. **Creates resource group** (if it doesn't exist)
4. **Creates Log Analytics workspace** (if it doesn't exist)
5. **Generates test data** with realistic security event patterns
6. **Ingests data** using the HTTP Data Collector API
7. **Provides summary** and query examples

## Test Data Schema

The generated test data includes the following fields:

| Field | Type | Description |
|-------|------|-------------|
| TimeGenerated | datetime | Event timestamp |
| EventType | string | Type of event (Login, Logout, etc.) |
| UserName | string | Username associated with the event |
| SourceSystem | string | Source system generating the event |
| EventId | string | Unique event identifier (GUID) |
| Severity | int | Event severity (1-4) |
| Message | string | Event message |
| IPAddress | string | Source IP address |
| Success | boolean | Whether the event was successful |

## Sample Queries

Once data is ingested, you can use these KQL queries in Log Analytics or Sentinel:

```kql
// Count all records
AuxiliaryTestData_CL | count

// Recent events (last hour)
AuxiliaryTestData_CL 
| where TimeGenerated > ago(1h) 
| take 10

// Event summary by type
AuxiliaryTestData_CL 
| summarize Count=count() by EventType 
| order by Count desc

// Failed events
AuxiliaryTestData_CL 
| where Success == false 
| project TimeGenerated, EventType, UserName, Message

// Timeline of events
AuxiliaryTestData_CL 
| summarize Count=count() by bin(TimeGenerated, 5m) 
| order by TimeGenerated desc
```

## Troubleshooting

### Data Not Appearing
- Wait 5-10 minutes after ingestion for data to become available
- Check that the workspace is properly configured
- Verify your permissions

### Authentication Issues
- Ensure you have the required Azure permissions
- Try running `Connect-AzAccount` manually first
- Check if MFA is required for your account

### Module Installation Issues
- Run PowerShell as Administrator
- Use `Install-Module -Name Az -Force -AllowClobber`
- Check PowerShell execution policy: `Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser`

## Security Considerations

- The test data is synthetic and safe for demonstration
- Workspace keys are handled securely within the script
- Consider using managed identities for production scenarios
- Review and customize the data schema for your specific needs

## Next Steps

After successful setup, you can:
1. **Create custom analytics rules** in Microsoft Sentinel
2. **Build workbooks** for data visualization
3. **Set up automated responses** using playbooks
4. **Integrate with other security tools**

## Support

For issues with this automation:
1. Check the troubleshooting section above
2. Review Azure PowerShell documentation
3. Consult Microsoft Sentinel documentation
4. Check Azure service health status
