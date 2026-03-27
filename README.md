# Sentinel Things

A collection of PowerShell scripts, KQL queries, and Azure Functions for working with Microsoft Sentinel, Microsoft Defender, and related Azure security services.

---

## Repository Contents

### PowerShell Scripts

| File | Description |
|------|-------------|
| [Get-SentinelConnectors.ps1](Get-SentinelConnectors.ps1) | Migration assessment tool that auto-installs Azure CLI, logs in, discovers all Sentinel instances across subscriptions via Resource Graph, and extracts a full inventory of data connectors from three sources: Data Connector resources (REST API), Content Hub connector definitions, and Data Collection Rules. Outputs a CSV with migration complexity ratings (Low/Medium/High) and per-connector migration notes. |
| [EnableRulesFromImportedSentinelAnalyticsRulesFromContentHub.ps1](EnableRulesFromImportedSentinelAnalyticsRulesFromContentHub.ps1) | Enumerates all Sentinel alert rule templates in a workspace and bulk-enables them as custom rules. Set `$resourceGroupName` and `$workspaceName` before running. |
| [createcustomtableauxiliary.ps1](createcustomtableauxiliary.ps1) | Creates a custom auxiliary-plan table in a Log Analytics workspace via the Azure REST API. Replace the placeholder subscription, resource group, and workspace values in the URI before running. |
| [uploadAcsvToSentinel.ps1](uploadAcsvToSentinel.ps1) | Reads a local CSV file and posts its contents to a custom Log Analytics table using the HTTP Data Collector API. Requires workspace ID and key to be filled in. |

### KQL Queries

| File | Description |
|------|-------------|
| [anomal_outboundaccessanomaly.kql](anomal_outboundaccessanomaly.kql) | Detects uncommon outbound network connections from server-class devices (Windows Server / Linux) using `series_decompose_anomalies` over a 7-day baseline against `DeviceNetworkEvents`. |
| [arborinsyslogparser.kql](arborinsyslogparser.kql) | Parses syslog messages from Arbor Networks APS (DDoS protection) and DNS query logs into structured fields including blocked host, threat category, protocol, source/destination IPs, and DNS response data. |
| [DeviceNotOnboarded.kql](DeviceNotOnboarded.kql) | Joins `AlertInfo` with `AlertEvidence` and `DeviceInfo` to surface alerts for devices that are not onboarded to Defender, helping identify unmanaged endpoints generating security events. |
| [logons.kql](logons.kql) | Correlates failed logon attempts across three data sources -- `BehaviorAnalytics`, `SigninLogs`, and `DeviceLogonEvents` -- and unions the results. Configurable failure threshold (default 4) and time window (default 24 hours). |
| [opnSenseFilterLogParser.kql](opnSenseFilterLogParser.kql) | Parses OPNsense firewall `filterlog` CSV-formatted syslog into structured fields covering IPv4/IPv6 headers, TCP/UDP ports, flags, sequence numbers, and protocol metadata. |

### Usage Monitoring Queries

Located in the `usagemon/` folder. These KQL queries help track Log Analytics ingestion volumes and billing.

| File | Description |
|------|-------------|
| [usagemon/UsageDailyGB.kql](usagemon/UsageDailyGB.kql) | Daily total data ingestion in GB from the `Usage` table over the last 30 days. |
| [usagemon/UsageDailyGBWithBilling.kql](usagemon/UsageDailyGBWithBilling.kql) | Same as above but splits output into billable vs non-billable GB per day. |
| [usagemon/OperationAllowanceUsage.kql](usagemon/OperationAllowanceUsage.kql) | Shows daily benefit/allowance usage from Defender for Servers and Sentinel M365 data allowances via the `Operation` table. |

### Auxiliary Table Stress Tester

Located in `auxiliaryStressTester/`. A suite of PowerShell scripts for creating auxiliary tables in Sentinel and ingesting bulk test data for cost and performance testing. See [auxiliaryStressTester/README.md](auxiliaryStressTester/README.md) for detailed usage.

| File | Description |
|------|-------------|
| [auxiliaryStressTester/Setup-SentinelAuxiliaryTable.ps1](auxiliaryStressTester/Setup-SentinelAuxiliaryTable.ps1) | Creates a Log Analytics workspace (if needed) and an auxiliary table, then ingests initial test data. |
| [auxiliaryStressTester/Bulk-Ingest.ps1](auxiliaryStressTester/Bulk-Ingest.ps1) | High-volume data ingestion (up to millions of records) for load and cost testing. |
| [auxiliaryStressTester/Query-SentinelData.ps1](auxiliaryStressTester/Query-SentinelData.ps1) | Utility to run predefined or custom KQL queries against the test table. |
| [auxiliaryStressTester/Connect-Azure.ps1](auxiliaryStressTester/Connect-Azure.ps1) | Authentication helper using device code flow. |
| [auxiliaryStressTester/config.json](auxiliaryStressTester/config.json) | Configuration template for Azure resource details. |

### Purview Audit for Copilot

Located in `purviewAuditForCopilot/`. An Azure Functions (v4, .NET 8) project that pulls Microsoft 365 Copilot interaction audit logs from the Office 365 Management Activity API and forwards them to a Sentinel custom table on a timer schedule.

| File | Description |
|------|-------------|
| [purviewAuditForCopilot/CopilotAuditFunction/CopilotAuditFunction.cs](purviewAuditForCopilot/CopilotAuditFunction/CopilotAuditFunction.cs) | Main function: subscribes to `Audit.General`, filters for Copilot records (RecordType 261, CopilotInteraction operations), and sends them to Sentinel via the HTTP Data Collector API. |
| [purviewAuditForCopilot/CopilotAuditFunction/Program.cs](purviewAuditForCopilot/CopilotAuditFunction/Program.cs) | Host builder with Application Insights and HttpClient DI registration. |
| [purviewAuditForCopilot/CopilotAuditFunction/host.json](purviewAuditForCopilot/CopilotAuditFunction/host.json) | Function app configuration with retry policy and 10-minute timeout. |

---

## Prerequisites

- **PowerShell 5.1+** (Windows) or **PowerShell 7+** (cross-platform) for the `.ps1` scripts
- **Azure CLI** -- `Get-SentinelConnectors.ps1` will install it automatically; other scripts may require it or the `Az` PowerShell modules
- **Az PowerShell Modules** -- `Az.Accounts`, `Az.OperationalInsights`, `Az.Resources`, `Az.SecurityInsights` (installed automatically by some scripts)
- **.NET 8 SDK** -- required only if building the Copilot audit Azure Function
- Appropriate **Azure RBAC permissions**: Contributor or Sentinel Contributor on the target subscription/resource group

## Quick Start

```powershell
# List Sentinel data connectors interactively (auto-installs Azure CLI if needed)
.\Get-SentinelConnectors.ps1

# Bulk-enable all Sentinel analytics rule templates
# Set $resourceGroupName and $workspaceName inside the script first
.\EnableRulesFromImportedSentinelAnalyticsRulesFromContentHub.ps1

# Create a custom auxiliary table
# Replace SUBID, RGNAME, WKSNAME in the URI first
.\createcustomtableauxiliary.ps1

# Upload CSV data to a custom Sentinel table
# Set $workspaceId and $workspaceKey first
.\uploadAcsvToSentinel.ps1
```

The KQL queries (`.kql` files) are meant to be run directly in the Log Analytics query editor or within Sentinel workbooks.

## Suggestions for Future Additions

Below are tools and queries that would complement the existing collection:

- **Sentinel Incident Exporter** -- a script to export Sentinel incidents (with alerts, entities, and comments) to CSV or JSON for offline analysis and reporting.
- **Watchlist Manager** -- a script to bulk-create, update, or delete Sentinel watchlists and their items from CSV files.
- **Analytics Rule Health Check** -- a KQL query or script that identifies disabled, misconfigured, or never-triggered analytics rules in a workspace.
- **Data Connector Health Dashboard** -- a KQL workbook query that checks connector last-log-received timestamps and flags stale or broken connectors.
- **Automation Rule / Playbook Inventory** -- a script to list all automation rules and their linked playbooks, showing enabled state and last-triggered time.
- **Workspace Cost Forecast** -- a KQL query joining `Usage` with `Operation` to project 30-day cost trends and alert when ingestion exceeds a threshold.

## License

This repository is provided as-is for internal use. No warranty is expressed or implied.
