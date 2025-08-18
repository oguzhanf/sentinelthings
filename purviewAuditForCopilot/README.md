# Microsoft 365 Copilot Audit Log Ingestion Solution

This solution provides automated ingestion of Microsoft 365 Copilot audit activities into Microsoft Sentinel using Azure Logic Apps. The solution creates a custom table `copilotauditlogs_cl` in your Sentinel workspace and continuously monitors for new Copilot audit events.

## 🏗️ Architecture Overview

The solution follows a secure, serverless architecture pattern:

**Data Flow:**
1. Microsoft 365 Copilot activities generate audit logs
2. Azure Logic App queries Office 365 Management API hourly
3. Retrieved audit data is transformed and sent to Sentinel
4. Data is stored in the custom `copilotauditlogs_cl` table

**Security:**
- Managed Identity for secure authentication
- RBAC-based permissions
- No stored credentials or secrets

### Components

- **Azure Logic App**: Orchestrates data retrieval and ingestion
- **Managed Identity**: Provides secure authentication
- **Office 365 Management API**: Source for Copilot audit activities
- **Custom Table**: `copilotauditlogs_cl` in Microsoft Sentinel
- **Log Analytics HTTP Data Collector API**: Target for data ingestion

## 📋 Prerequisites

### Azure Requirements
- Azure subscription with appropriate permissions
- Microsoft Sentinel workspace (Log Analytics workspace)
- Azure Logic Apps service available in your region
- Global Administrator or Security Administrator role for API permissions

### PowerShell Requirements
- PowerShell 5.1 or PowerShell 7+
- Required modules (auto-installed by scripts):
  - `Az.Accounts`
  - `Az.Resources`
  - `Az.OperationalInsights`
  - `Az.LogicApp`
  - `Microsoft.Graph.Authentication`
  - `Microsoft.Graph.Applications`

### Azure CLI Requirements (Optional)
- Azure CLI 2.0 or later
- Bash shell (Linux/macOS) or WSL (Windows)

## 🚀 Quick Start Deployment

### Option 1: PowerShell Deployment (Recommended)

1. **Clone the repository and navigate to the solution directory:**
   ```powershell
   cd purviewAuditForCopilot
   ```

2. **Run the deployment script:**
   ```powershell
   .\Deploy-CopilotAuditSolution.ps1 -SubscriptionId "your-subscription-id" -ResourceGroupName "rg-sentinel" -WorkspaceName "law-sentinel"
   ```

3. **Follow the authentication prompts** for Azure device login.

### Option 2: Azure CLI Deployment

1. **Make the script executable:**
   ```bash
   chmod +x azure-cli-commands.sh
   ```

2. **Update configuration variables in the script:**
   ```bash
   # Edit azure-cli-commands.sh and update these variables:
   SUBSCRIPTION_ID="your-subscription-id"
   RESOURCE_GROUP_NAME="rg-sentinel-copilot"
   WORKSPACE_NAME="law-sentinel"
   ```

3. **Run the deployment:**
   ```bash
   ./azure-cli-commands.sh deploy
   ```

### Option 3: Manual Step-by-Step Deployment

1. **Create the custom table:**
   ```powershell
   .\Create-CopilotAuditTable.ps1 -SubscriptionId "your-sub-id" -ResourceGroupName "rg-sentinel" -WorkspaceName "law-sentinel"
   ```

2. **Deploy the Logic App using ARM template:**
   ```powershell
   az deployment group create --resource-group "rg-sentinel" --template-file "infrastructure/arm-template.json" --parameters @parameters.json
   ```

3. **Configure authentication:**
   ```powershell
   .\Setup-Authentication.ps1 -SubscriptionId "your-sub-id" -ResourceGroupName "rg-sentinel" -LogicAppName "copilot-audit-ingestion" -WorkspaceResourceId "/subscriptions/.../workspaces/law-sentinel"
   ```

## 🧪 Testing and Validation

### Run Comprehensive Tests

```powershell
.\Test-CopilotAuditSolution.ps1 -SubscriptionId "your-sub-id" -ResourceGroupName "rg-sentinel" -WorkspaceName "law-sentinel" -TestDataIngestion -RunEndToEndTest
```

### Validate Deployment Only

```powershell
.\Test-CopilotAuditSolution.ps1 -SubscriptionId "your-sub-id" -ResourceGroupName "rg-sentinel" -WorkspaceName "law-sentinel"
```

### Query Ingested Data

In Microsoft Sentinel, use this KQL query to check for ingested data:

```kql
copilotauditlogs_cl
| take 10
| order by TimeGenerated desc
```

## 📊 Custom Table Schema

The `copilotauditlogs_cl` table includes the following columns:

| Column | Type | Description |
|--------|------|-------------|
| TimeGenerated | datetime | Event timestamp |
| ActivityId | string | Unique activity identifier |
| ActivityType | string | Type of Copilot activity |
| UserId | string | User identifier |
| UserPrincipalName | string | User principal name |
| ClientIP | string | Client IP address |
| UserAgent | string | User agent string |
| AppName | string | Application name |
| AppId | string | Application identifier |
| CopilotEventType | string | Specific Copilot event type |
| ContentType | string | Type of content accessed |
| ContentId | string | Content identifier |
| ContentName | string | Content name |
| ContentUrl | string | Content URL |
| QueryText | string | User query text |
| ResponseText | string | Copilot response |
| TokensUsed | int | Number of tokens consumed |
| SessionId | string | Session identifier |
| ConversationId | string | Conversation identifier |
| TenantId | string | Azure AD tenant ID |
| OrganizationId | string | Organization identifier |
| ResultStatus | string | Operation result status |
| ErrorCode | string | Error code (if any) |
| ErrorMessage | string | Error message (if any) |
| SourceSystem | string | Source system identifier |
| AdditionalProperties | dynamic | Additional event properties |

## 🔧 Configuration Options

### Logic App Trigger Frequency

Modify the recurrence frequency in the deployment parameters:

```powershell
# Deploy with custom frequency
.\Deploy-CopilotAuditSolution.ps1 -SubscriptionId "your-sub-id" -ResourceGroupName "rg-sentinel" -WorkspaceName "law-sentinel" -RecurrenceFrequency "Minute" -RecurrenceInterval 30
```

### Data Retention

Modify the retention period when creating the custom table:

```powershell
.\Create-CopilotAuditTable.ps1 -SubscriptionId "your-sub-id" -ResourceGroupName "rg-sentinel" -WorkspaceName "law-sentinel" -RetentionDays 730
```

## 🔐 Security and Permissions

### Required API Permissions

The Logic App managed identity requires the following permissions:

**Office 365 Management APIs:**
- `ActivityFeed.Read`
- `ActivityFeed.ReadDlp`
- `ServiceHealth.Read`

**Azure RBAC:**
- `Log Analytics Contributor` on the Sentinel workspace

### Manual Permission Configuration

If automatic permission setup fails, configure manually:

1. Go to **Azure AD > Enterprise Applications**
2. Find your Logic App managed identity
3. Add API permissions for Office 365 Management APIs
4. Grant admin consent for the permissions

## 📁 File Structure

```
purviewAuditForCopilot/
├── README.md                           # This documentation
├── Create-CopilotAuditTable.ps1       # Custom table creation script
├── Deploy-CopilotAuditSolution.ps1    # Main deployment script
├── Setup-Authentication.ps1           # Authentication configuration
├── Test-CopilotAuditSolution.ps1      # Testing and validation
├── azure-cli-commands.sh              # Azure CLI deployment script
├── logic-app-workflow.json            # Logic App workflow definition
└── infrastructure/
    ├── arm-template.json               # ARM template
    ├── main.bicep                      # Bicep template
    └── main.tf                         # Terraform configuration
```

## 🔍 Monitoring and Troubleshooting

### Check Logic App Status

```powershell
Get-AzLogicApp -ResourceGroupName "rg-sentinel" -Name "copilot-audit-ingestion"
```

### View Logic App Run History

1. Go to Azure Portal
2. Navigate to your Logic App
3. Check **Run history** for execution details

### Common Issues and Solutions

| Issue | Solution |
|-------|----------|
| Logic App fails to authenticate | Verify managed identity permissions |
| No data in custom table | Check Office 365 audit log availability |
| Permission denied errors | Ensure proper RBAC assignments |
| Table creation fails | Verify Log Analytics workspace permissions |

### Troubleshooting Commands

```bash
# Show troubleshooting commands
./azure-cli-commands.sh troubleshoot
```

## 📈 Monitoring Queries

### Monitor Logic App Execution

```kql
AzureDiagnostics
| where ResourceProvider == "MICROSOFT.LOGIC"
| where ResourceType == "WORKFLOWS"
| where Resource == "copilot-audit-ingestion"
| order by TimeGenerated desc
```

### Check Data Ingestion Rate

```kql
copilotauditlogs_cl
| summarize count() by bin(TimeGenerated, 1h)
| order by TimeGenerated desc
```

### Monitor User Activity

```kql
copilotauditlogs_cl
| summarize ActivityCount = count() by UserPrincipalName, bin(TimeGenerated, 1d)
| order by TimeGenerated desc, ActivityCount desc
```

## 🔄 Maintenance

### Update Logic App Workflow

1. Modify `logic-app-workflow.json`
2. Redeploy using the deployment script
3. Test the updated workflow

### Scale Considerations

- Logic App: Automatically scales based on trigger frequency
- Custom Table: Monitor ingestion costs and adjust retention as needed
- API Limits: Office 365 Management API has rate limits

## 📞 Support

For issues and questions:

1. Check the troubleshooting section
2. Review Azure Logic App run history
3. Validate permissions and configuration
4. Check Microsoft 365 audit log availability

## 📄 License

This solution is provided as-is under the MIT License. See LICENSE file for details.

## 🤝 Contributing

Contributions are welcome! Please:

1. Fork the repository
2. Create a feature branch
3. Submit a pull request with detailed description

---

**Note**: This solution requires Microsoft 365 E5 or equivalent licensing for Copilot audit log availability.
