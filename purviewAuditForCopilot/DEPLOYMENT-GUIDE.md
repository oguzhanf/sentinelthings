# Microsoft 365 Copilot Audit Log Ingestion - Deployment Guide

This comprehensive guide walks you through deploying the Microsoft 365 Copilot audit log ingestion solution step by step.

## 📋 Pre-Deployment Checklist

### Azure Environment
- [ ] Azure subscription with Owner or Contributor permissions
- [ ] Microsoft Sentinel workspace deployed and configured
- [ ] Resource group created or identified for deployment
- [ ] Azure Logic Apps service available in target region

### Microsoft 365 Environment
- [ ] Microsoft 365 E5 or equivalent licensing
- [ ] Global Administrator or Security Administrator role
- [ ] Office 365 Management API access enabled
- [ ] Copilot for Microsoft 365 deployed and in use

### Local Environment
- [ ] PowerShell 5.1+ or PowerShell 7+ installed
- [ ] Azure CLI 2.0+ installed (optional)
- [ ] Git client for repository access
- [ ] Network access to Azure and Microsoft 365 endpoints

## 🚀 Step-by-Step Deployment

### Step 1: Environment Preparation

1. **Clone the Repository**
   ```bash
   git clone https://github.com/your-org/sentinelthings.git
   cd sentinelthings/purviewAuditForCopilot
   ```

2. **Verify Prerequisites**
   ```powershell
   # Check PowerShell version
   $PSVersionTable.PSVersion
   
   # Check Azure CLI (if using)
   az --version
   ```

3. **Gather Required Information**
   - Azure Subscription ID
   - Resource Group Name
   - Log Analytics Workspace Name
   - Preferred Azure Region
   - Logic App Name (optional, defaults to "copilot-audit-ingestion")

### Step 2: Azure Authentication

1. **PowerShell Authentication**
   ```powershell
   # The deployment script will prompt for device authentication
   # Have your browser ready for the authentication flow
   ```

2. **Azure CLI Authentication (if using CLI method)**
   ```bash
   az login --use-device-code
   az account set --subscription "your-subscription-id"
   ```

### Step 3: Deploy Using PowerShell (Recommended)

1. **Run the Main Deployment Script**
   ```powershell
   .\Deploy-CopilotAuditSolution.ps1 `
       -SubscriptionId "12345678-1234-1234-1234-123456789012" `
       -ResourceGroupName "rg-sentinel-prod" `
       -WorkspaceName "law-sentinel-prod" `
       -Location "East US" `
       -LogicAppName "copilot-audit-ingestion"
   ```

2. **Monitor Deployment Progress**
   - The script will display colored output showing progress
   - Green messages indicate success
   - Yellow messages are warnings or informational
   - Red messages indicate errors

3. **Expected Deployment Time**
   - Custom table creation: 2-3 minutes
   - Logic App deployment: 3-5 minutes
   - Authentication setup: 2-3 minutes
   - Total: 7-11 minutes

### Step 4: Alternative CLI Deployment

1. **Update Configuration Variables**
   ```bash
   # Edit azure-cli-commands.sh
   SUBSCRIPTION_ID="your-subscription-id"
   RESOURCE_GROUP_NAME="rg-sentinel-prod"
   WORKSPACE_NAME="law-sentinel-prod"
   LOGIC_APP_NAME="copilot-audit-ingestion"
   LOCATION="eastus"
   ```

2. **Execute Deployment**
   ```bash
   chmod +x azure-cli-commands.sh
   ./azure-cli-commands.sh deploy
   ```

### Step 5: Manual Permission Configuration

The deployment script attempts to configure permissions automatically, but manual steps may be required:

1. **Navigate to Azure AD Admin Center**
   - Go to https://aad.portal.azure.com
   - Select "Enterprise applications"

2. **Find Logic App Managed Identity**
   - Search for your Logic App name
   - Select the managed identity entry

3. **Configure API Permissions**
   - Go to "API permissions"
   - Add permissions for "Office 365 Management APIs"
   - Add the following permissions:
     - ActivityFeed.Read
     - ActivityFeed.ReadDlp
     - ServiceHealth.Read

4. **Grant Admin Consent**
   - Click "Grant admin consent for [your organization]"
   - Confirm the consent

### Step 6: Validation and Testing

1. **Run Validation Tests**
   ```powershell
   .\Test-CopilotAuditSolution.ps1 `
       -SubscriptionId "your-subscription-id" `
       -ResourceGroupName "rg-sentinel-prod" `
       -WorkspaceName "law-sentinel-prod" `
       -TestDataIngestion
   ```

2. **Check Logic App Status**
   ```powershell
   Get-AzLogicApp -ResourceGroupName "rg-sentinel-prod" -Name "copilot-audit-ingestion"
   ```

3. **Verify Custom Table**
   In Microsoft Sentinel, run this KQL query:
   ```kql
   search "copilotauditlogs_cl"
   | take 1
   ```

## 🔧 Configuration Options

### Deployment Parameters

| Parameter | Description | Default | Options |
|-----------|-------------|---------|---------|
| SubscriptionId | Azure subscription ID | Required | GUID |
| ResourceGroupName | Resource group name | Required | String |
| WorkspaceName | Log Analytics workspace | Required | String |
| Location | Azure region | "East US" | Azure regions |
| LogicAppName | Logic App name | "copilot-audit-ingestion" | String |
| RecurrenceFrequency | Trigger frequency | "Hour" | Minute, Hour, Day |
| RecurrenceInterval | Trigger interval | 1 | Integer |

### Advanced Configuration

1. **Custom Retention Period**
   ```powershell
   .\Create-CopilotAuditTable.ps1 `
       -SubscriptionId "your-sub-id" `
       -ResourceGroupName "rg-sentinel" `
       -WorkspaceName "law-sentinel" `
       -RetentionDays 730
   ```

2. **High-Frequency Monitoring**
   ```powershell
   .\Deploy-CopilotAuditSolution.ps1 `
       -SubscriptionId "your-sub-id" `
       -ResourceGroupName "rg-sentinel" `
       -WorkspaceName "law-sentinel" `
       -RecurrenceFrequency "Minute" `
       -RecurrenceInterval 15
   ```

## 🔍 Post-Deployment Verification

### 1. Azure Portal Checks

1. **Logic App Status**
   - Navigate to Azure Portal > Logic Apps
   - Find your Logic App
   - Verify status is "Enabled"
   - Check "Run history" for successful executions

2. **Managed Identity**
   - In Logic App settings, go to "Identity"
   - Verify "System assigned" is "On"
   - Note the Object (principal) ID

3. **Role Assignments**
   - Navigate to your Log Analytics workspace
   - Go to "Access control (IAM)"
   - Verify Logic App has "Log Analytics Contributor" role

### 2. Microsoft Sentinel Checks

1. **Custom Table Verification**
   ```kql
   union withsource=TableName *
   | where TableName == "copilotauditlogs_cl"
   | take 1
   ```

2. **Schema Validation**
   ```kql
   copilotauditlogs_cl
   | getschema
   ```

### 3. Data Flow Verification

1. **Wait for Copilot Activity**
   - Ensure users are actively using Copilot
   - Wait 1-2 hours for the Logic App to run

2. **Check for Data**
   ```kql
   copilotauditlogs_cl
   | where TimeGenerated > ago(24h)
   | take 10
   ```

## 🚨 Troubleshooting Common Issues

### Issue: Logic App Authentication Fails

**Symptoms:**
- Logic App runs fail with authentication errors
- HTTP 401 or 403 responses

**Solutions:**
1. Verify managed identity is enabled
2. Check API permissions are granted
3. Ensure admin consent is provided
4. Verify tenant ID is correct

### Issue: No Data in Custom Table

**Symptoms:**
- Logic App runs successfully
- No data appears in copilotauditlogs_cl table

**Solutions:**
1. Verify Copilot activities are occurring
2. Check Office 365 audit log retention settings
3. Verify Logic App is querying correct time range
4. Check for API rate limiting

### Issue: Custom Table Creation Fails

**Symptoms:**
- Table creation script fails
- Permission denied errors

**Solutions:**
1. Verify Log Analytics workspace permissions
2. Check subscription and resource group access
3. Ensure workspace exists and is accessible
4. Try manual table creation via Azure Portal

### Issue: High Costs

**Symptoms:**
- Unexpected Azure costs
- High Log Analytics ingestion charges

**Solutions:**
1. Adjust Logic App trigger frequency
2. Implement data filtering in Logic App
3. Review table retention settings
4. Monitor ingestion volume

## 📊 Monitoring and Maintenance

### Regular Monitoring Tasks

1. **Weekly Checks**
   - Verify Logic App execution success rate
   - Check data ingestion volume
   - Review any error messages

2. **Monthly Reviews**
   - Analyze cost trends
   - Review retention policies
   - Update documentation if needed

3. **Quarterly Assessments**
   - Review security permissions
   - Update solution components
   - Assess performance optimization opportunities

### Monitoring Queries

```kql
// Logic App execution monitoring
AzureDiagnostics
| where ResourceProvider == "MICROSOFT.LOGIC"
| where Resource == "copilot-audit-ingestion"
| summarize count() by ResultType, bin(TimeGenerated, 1h)

// Data ingestion rate
copilotauditlogs_cl
| summarize count() by bin(TimeGenerated, 1h)
| render timechart

// User activity summary
copilotauditlogs_cl
| where TimeGenerated > ago(7d)
| summarize Activities = count() by UserPrincipalName
| top 10 by Activities
```

## 🔄 Updates and Upgrades

### Updating the Solution

1. **Pull Latest Changes**
   ```bash
   git pull origin main
   ```

2. **Review Changes**
   - Check CHANGELOG.md for breaking changes
   - Review updated documentation

3. **Test in Development**
   - Deploy to test environment first
   - Validate functionality

4. **Deploy to Production**
   - Use the same deployment process
   - Monitor for issues post-deployment

### Version Management

- Tag stable releases in Git
- Maintain deployment logs
- Document configuration changes
- Keep backup of working configurations

---

**Next Steps:** After successful deployment, proceed to the [README.md](README.md) for operational guidance and monitoring instructions.
