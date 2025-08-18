# Configure the Azure Provider
terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~>3.0"
    }
  }
  required_version = ">= 1.0"
}

# Configure the Microsoft Azure Provider
provider "azurerm" {
  features {}
}

# Variables
variable "logic_app_name" {
  description = "Name of the Logic App"
  type        = string
  default     = "copilot-audit-ingestion"
}

variable "location" {
  description = "Location for all resources"
  type        = string
  default     = "East US"
}

variable "resource_group_name" {
  description = "Name of the resource group"
  type        = string
}

variable "tenant_id" {
  description = "Azure AD Tenant ID"
  type        = string
}

variable "workspace_resource_id" {
  description = "Resource ID of the Log Analytics workspace (Sentinel)"
  type        = string
}

variable "workspace_id" {
  description = "Log Analytics Workspace ID (GUID)"
  type        = string
}

variable "workspace_key" {
  description = "Log Analytics Workspace Primary Key"
  type        = string
  sensitive   = true
}

variable "recurrence_frequency" {
  description = "Frequency for the Logic App trigger"
  type        = string
  default     = "Hour"
  validation {
    condition     = contains(["Minute", "Hour", "Day"], var.recurrence_frequency)
    error_message = "Recurrence frequency must be one of: Minute, Hour, Day."
  }
}

variable "recurrence_interval" {
  description = "Interval for the Logic App trigger"
  type        = number
  default     = 1
}

variable "enable_system_assigned_identity" {
  description = "Enable system-assigned managed identity for the Logic App"
  type        = bool
  default     = true
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default = {
    Environment = "Production"
    Purpose     = "CopilotAuditIngestion"
    Owner       = "SecurityTeam"
  }
}

# Data sources
data "azurerm_client_config" "current" {}

data "azurerm_resource_group" "main" {
  name = var.resource_group_name
}

# Extract workspace details from resource ID
locals {
  workspace_resource_group = split("/", var.workspace_resource_id)[4]
  workspace_name           = split("/", var.workspace_resource_id)[8]
}

# Logic App for Copilot audit log ingestion
resource "azurerm_logic_app_workflow" "copilot_audit_ingestion" {
  name                = var.logic_app_name
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = var.tags

  identity {
    type = var.enable_system_assigned_identity ? "SystemAssigned" : null
  }

  workflow_schema   = "https://schema.management.azure.com/providers/Microsoft.Logic/schemas/2016-06-01/workflowdefinition.json#"
  workflow_version  = "1.0.0.0"
  
  parameters = {
    "tenantId" = {
      type         = "string"
      defaultValue = var.tenant_id
    }
    "workspaceId" = {
      type         = "string"
      defaultValue = var.workspace_id
    }
    "workspaceKey" = {
      type         = "securestring"
      defaultValue = var.workspace_key
    }
  }

  workflow_parameters = {
    tenantId     = var.tenant_id
    workspaceId  = var.workspace_id
    workspaceKey = var.workspace_key
  }
}

# Logic App Trigger
resource "azurerm_logic_app_trigger_recurrence" "copilot_audit_trigger" {
  name         = "Recurrence"
  logic_app_id = azurerm_logic_app_workflow.copilot_audit_ingestion.id
  frequency    = var.recurrence_frequency
  interval     = var.recurrence_interval
  time_zone    = "UTC"
}

# Logic App Actions - Initialize StartTime
resource "azurerm_logic_app_action_custom" "initialize_start_time" {
  name         = "Initialize_StartTime"
  logic_app_id = azurerm_logic_app_workflow.copilot_audit_ingestion.id

  body = jsonencode({
    type = "InitializeVariable"
    inputs = {
      variables = [
        {
          name  = "StartTime"
          type  = "string"
          value = "@{addHours(utcNow(), -1)}"
        }
      ]
    }
  })

  depends_on = [azurerm_logic_app_trigger_recurrence.copilot_audit_trigger]
}

# Logic App Actions - Initialize EndTime
resource "azurerm_logic_app_action_custom" "initialize_end_time" {
  name         = "Initialize_EndTime"
  logic_app_id = azurerm_logic_app_workflow.copilot_audit_ingestion.id

  body = jsonencode({
    type = "InitializeVariable"
    inputs = {
      variables = [
        {
          name  = "EndTime"
          type  = "string"
          value = "@{utcNow()}"
        }
      ]
    }
    runAfter = {
      Initialize_StartTime = ["Succeeded"]
    }
  })

  depends_on = [azurerm_logic_app_action_custom.initialize_start_time]
}

# Get workspace resource group for role assignment
data "azurerm_resource_group" "workspace_rg" {
  name = local.workspace_resource_group
}

# Role assignment for Log Analytics Contributor
resource "azurerm_role_assignment" "log_analytics_contributor" {
  count                = var.enable_system_assigned_identity ? 1 : 0
  scope                = data.azurerm_resource_group.workspace_rg.id
  role_definition_name = "Log Analytics Contributor"
  principal_id         = azurerm_logic_app_workflow.copilot_audit_ingestion.identity[0].principal_id
}

# Outputs
output "logic_app_resource_id" {
  description = "Resource ID of the Logic App"
  value       = azurerm_logic_app_workflow.copilot_audit_ingestion.id
}

output "logic_app_name" {
  description = "Name of the Logic App"
  value       = azurerm_logic_app_workflow.copilot_audit_ingestion.name
}

output "principal_id" {
  description = "Principal ID of the Logic App managed identity"
  value       = var.enable_system_assigned_identity ? azurerm_logic_app_workflow.copilot_audit_ingestion.identity[0].principal_id : ""
}

output "managed_identity_tenant_id" {
  description = "Tenant ID of the Logic App managed identity"
  value       = var.enable_system_assigned_identity ? azurerm_logic_app_workflow.copilot_audit_ingestion.identity[0].tenant_id : ""
}

output "access_endpoint" {
  description = "Access endpoint for the Logic App"
  value       = azurerm_logic_app_workflow.copilot_audit_ingestion.access_endpoint
}
