@description('Name of the Logic App')
param logicAppName string = 'copilot-audit-ingestion'

@description('Location for all resources')
param location string = resourceGroup().location

@description('Azure AD Tenant ID')
param tenantId string = subscription().tenantId

@description('Resource ID of the Log Analytics workspace (Sentinel)')
param workspaceResourceId string

@description('Log Analytics Workspace ID (GUID)')
param workspaceId string

@description('Log Analytics Workspace Primary Key')
@secure()
param workspaceKey string

@description('Frequency for the Logic App trigger')
@allowed([
  'Minute'
  'Hour'
  'Day'
])
param recurrenceFrequency string = 'Hour'

@description('Interval for the Logic App trigger')
param recurrenceInterval int = 1

@description('Enable system-assigned managed identity for the Logic App')
param enableSystemAssignedIdentity bool = true

@description('Tags to apply to all resources')
param tags object = {
  Environment: 'Production'
  Purpose: 'CopilotAuditIngestion'
  Owner: 'SecurityTeam'
}

var workspaceResourceGroup = split(workspaceResourceId, '/')[4]
var workspaceName = split(workspaceResourceId, '/')[8]

// Logic App for Copilot audit log ingestion
resource logicApp 'Microsoft.Logic/workflows@2019-05-01' = {
  name: logicAppName
  location: location
  tags: tags
  identity: {
    type: enableSystemAssignedIdentity ? 'SystemAssigned' : 'None'
  }
  properties: {
    state: 'Enabled'
    definition: {
      '$schema': 'https://schema.management.azure.com/providers/Microsoft.Logic/schemas/2016-06-01/workflowdefinition.json#'
      contentVersion: '1.0.0.0'
      parameters: {
        tenantId: {
          type: 'string'
          defaultValue: tenantId
        }
        workspaceId: {
          type: 'string'
          defaultValue: workspaceId
        }
        workspaceKey: {
          type: 'securestring'
          defaultValue: workspaceKey
        }
      }
      triggers: {
        Recurrence: {
          type: 'Recurrence'
          recurrence: {
            frequency: recurrenceFrequency
            interval: recurrenceInterval
            timeZone: 'UTC'
          }
        }
      }
      actions: {
        Initialize_StartTime: {
          type: 'InitializeVariable'
          inputs: {
            variables: [
              {
                name: 'StartTime'
                type: 'string'
                value: '@{addHours(utcNow(), -1)}'
              }
            ]
          }
        }
        Initialize_EndTime: {
          type: 'InitializeVariable'
          inputs: {
            variables: [
              {
                name: 'EndTime'
                type: 'string'
                value: '@{utcNow()}'
              }
            ]
          }
          runAfter: {
            Initialize_StartTime: [
              'Succeeded'
            ]
          }
        }
        Get_Access_Token: {
          type: 'Http'
          inputs: {
            method: 'POST'
            uri: 'https://login.microsoftonline.com/@{parameters(\'tenantId\')}/oauth2/v2.0/token'
            headers: {
              'Content-Type': 'application/x-www-form-urlencoded'
            }
            body: 'grant_type=client_credentials&scope=https://manage.office.com/.default'
            authentication: {
              type: 'ManagedServiceIdentity'
            }
          }
          runAfter: {
            Initialize_EndTime: [
              'Succeeded'
            ]
          }
        }
        Parse_Token_Response: {
          type: 'ParseJson'
          inputs: {
            content: '@body(\'Get_Access_Token\')'
            schema: {
              type: 'object'
              properties: {
                access_token: {
                  type: 'string'
                }
                token_type: {
                  type: 'string'
                }
                expires_in: {
                  type: 'integer'
                }
              }
            }
          }
          runAfter: {
            Get_Access_Token: [
              'Succeeded'
            ]
          }
        }
        Get_Copilot_Audit_Logs: {
          type: 'Http'
          inputs: {
            method: 'GET'
            uri: 'https://manage.office.com/api/v1.0/@{parameters(\'tenantId\')}/activity/feed/subscriptions/content?contentType=Audit.Copilot&startTime=@{variables(\'StartTime\')}&endTime=@{variables(\'EndTime\')}'
            headers: {
              Authorization: 'Bearer @{body(\'Parse_Token_Response\')[\'access_token\']}'
              'Content-Type': 'application/json'
            }
          }
          runAfter: {
            Parse_Token_Response: [
              'Succeeded'
            ]
          }
        }
        Check_If_Logs_Available: {
          type: 'Condition'
          expression: {
            and: [
              {
                greater: [
                  '@length(body(\'Get_Copilot_Audit_Logs\'))'
                  0
                ]
              }
            ]
          }
          actions: {
            Process_Audit_Logs: {
              type: 'Compose'
              inputs: {
                message: 'Processing Copilot audit logs'
                count: '@length(body(\'Get_Copilot_Audit_Logs\'))'
              }
            }
          }
          runAfter: {
            Get_Copilot_Audit_Logs: [
              'Succeeded'
            ]
          }
          else: {
            actions: {
              Log_No_Data_Found: {
                type: 'Compose'
                inputs: {
                  message: 'No Copilot audit logs found'
                  startTime: '@variables(\'StartTime\')'
                  endTime: '@variables(\'EndTime\')'
                }
              }
            }
          }
        }
      }
    }
  }
}

// Role assignment for Log Analytics Contributor
resource logAnalyticsContributorRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (enableSystemAssignedIdentity) {
  name: guid(logicApp.id, workspaceResourceId, 'Log Analytics Contributor')
  scope: resourceGroup(workspaceResourceGroup)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '92aaf0da-9dab-42b6-94a3-d43ce8d16293')
    principalId: logicApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

@description('Resource ID of the Logic App')
output logicAppResourceId string = logicApp.id

@description('Name of the Logic App')
output logicAppName string = logicApp.name

@description('Principal ID of the Logic App managed identity')
output principalId string = enableSystemAssignedIdentity ? logicApp.identity.principalId : ''

@description('Tenant ID of the Logic App managed identity')
output managedIdentityTenantId string = enableSystemAssignedIdentity ? logicApp.identity.tenantId : ''

@description('Logic App trigger URL')
output triggerUrl string = listCallbackUrl(resourceId('Microsoft.Logic/workflows/triggers', logicAppName, 'Recurrence'), '2019-05-01').value
