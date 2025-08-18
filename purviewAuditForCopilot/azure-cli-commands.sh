#!/bin/bash

# Microsoft 365 Copilot Audit Log Ingestion Solution - Azure CLI Commands
# This script provides Azure CLI commands for deploying and managing the solution

# Set color output functions
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

print_header() {
    echo -e "${CYAN}=== $1 ===${NC}"
}

print_success() {
    echo -e "${GREEN}✓ $1${NC}"
}

print_warning() {
    echo -e "${YELLOW}⚠ $1${NC}"
}

print_error() {
    echo -e "${RED}✗ $1${NC}"
}

print_info() {
    echo -e "${BLUE}ℹ $1${NC}"
}

# Configuration variables (update these with your values)
SUBSCRIPTION_ID="your-subscription-id"
RESOURCE_GROUP_NAME="rg-sentinel-copilot"
WORKSPACE_NAME="law-sentinel"
LOGIC_APP_NAME="copilot-audit-ingestion"
LOCATION="eastus"
TABLE_NAME="copilotauditlogs_cl"

print_header "Microsoft 365 Copilot Audit Log Ingestion - Azure CLI Deployment"

# Function to check if Azure CLI is installed
check_azure_cli() {
    if ! command -v az &> /dev/null; then
        print_error "Azure CLI is not installed. Please install it first."
        echo "Visit: https://docs.microsoft.com/en-us/cli/azure/install-azure-cli"
        exit 1
    fi
    print_success "Azure CLI is installed"
}

# Function to login to Azure
azure_login() {
    print_info "Logging into Azure..."
    az login --use-device-code
    
    if [ $? -eq 0 ]; then
        print_success "Successfully logged into Azure"
    else
        print_error "Failed to login to Azure"
        exit 1
    fi
    
    # Set subscription
    print_info "Setting subscription: $SUBSCRIPTION_ID"
    az account set --subscription "$SUBSCRIPTION_ID"
    
    if [ $? -eq 0 ]; then
        print_success "Subscription set successfully"
    else
        print_error "Failed to set subscription"
        exit 1
    fi
}

# Function to create resource group
create_resource_group() {
    print_info "Creating resource group: $RESOURCE_GROUP_NAME"
    
    # Check if resource group exists
    if az group show --name "$RESOURCE_GROUP_NAME" &> /dev/null; then
        print_warning "Resource group already exists"
    else
        az group create --name "$RESOURCE_GROUP_NAME" --location "$LOCATION"
        
        if [ $? -eq 0 ]; then
            print_success "Resource group created successfully"
        else
            print_error "Failed to create resource group"
            exit 1
        fi
    fi
}

# Function to validate Log Analytics workspace
validate_workspace() {
    print_info "Validating Log Analytics workspace: $WORKSPACE_NAME"
    
    if az monitor log-analytics workspace show --resource-group "$RESOURCE_GROUP_NAME" --workspace-name "$WORKSPACE_NAME" &> /dev/null; then
        print_success "Log Analytics workspace found"
    else
        print_error "Log Analytics workspace not found. Please create it first or update the WORKSPACE_NAME variable."
        exit 1
    fi
}

# Function to create custom table using REST API
create_custom_table() {
    print_info "Creating custom table: $TABLE_NAME"
    
    # Get workspace details
    WORKSPACE_ID=$(az monitor log-analytics workspace show --resource-group "$RESOURCE_GROUP_NAME" --workspace-name "$WORKSPACE_NAME" --query "customerId" -o tsv)
    
    # Create table schema
    TABLE_SCHEMA='{
        "properties": {
            "schema": {
                "name": "'$TABLE_NAME'",
                "columns": [
                    {"name": "TimeGenerated", "type": "datetime"},
                    {"name": "ActivityId", "type": "string"},
                    {"name": "ActivityType", "type": "string"},
                    {"name": "UserId", "type": "string"},
                    {"name": "UserPrincipalName", "type": "string"},
                    {"name": "ClientIP", "type": "string"},
                    {"name": "UserAgent", "type": "string"},
                    {"name": "AppName", "type": "string"},
                    {"name": "AppId", "type": "string"},
                    {"name": "CopilotEventType", "type": "string"},
                    {"name": "ContentType", "type": "string"},
                    {"name": "ContentId", "type": "string"},
                    {"name": "ContentName", "type": "string"},
                    {"name": "ContentUrl", "type": "string"},
                    {"name": "QueryText", "type": "string"},
                    {"name": "ResponseText", "type": "string"},
                    {"name": "TokensUsed", "type": "int"},
                    {"name": "SessionId", "type": "string"},
                    {"name": "ConversationId", "type": "string"},
                    {"name": "TenantId", "type": "string"},
                    {"name": "OrganizationId", "type": "string"},
                    {"name": "ResultStatus", "type": "string"},
                    {"name": "ErrorCode", "type": "string"},
                    {"name": "ErrorMessage", "type": "string"},
                    {"name": "SourceSystem", "type": "string"},
                    {"name": "AdditionalProperties", "type": "dynamic"}
                ]
            },
            "totalRetentionInDays": 365,
            "plan": "Analytics"
        }
    }'
    
    # Create the table
    az rest --method PUT \
        --url "https://management.azure.com/subscriptions/$SUBSCRIPTION_ID/resourcegroups/$RESOURCE_GROUP_NAME/providers/microsoft.operationalinsights/workspaces/$WORKSPACE_NAME/tables/$TABLE_NAME?api-version=2023-01-01-preview" \
        --body "$TABLE_SCHEMA"
    
    if [ $? -eq 0 ]; then
        print_success "Custom table created successfully"
    else
        print_warning "Custom table creation may have failed or table already exists"
    fi
}

# Function to deploy Logic App using ARM template
deploy_logic_app() {
    print_info "Deploying Logic App: $LOGIC_APP_NAME"
    
    # Get workspace details
    WORKSPACE_ID=$(az monitor log-analytics workspace show --resource-group "$RESOURCE_GROUP_NAME" --workspace-name "$WORKSPACE_NAME" --query "customerId" -o tsv)
    WORKSPACE_RESOURCE_ID=$(az monitor log-analytics workspace show --resource-group "$RESOURCE_GROUP_NAME" --workspace-name "$WORKSPACE_NAME" --query "id" -o tsv)
    WORKSPACE_KEY=$(az monitor log-analytics workspace get-shared-keys --resource-group "$RESOURCE_GROUP_NAME" --workspace-name "$WORKSPACE_NAME" --query "primarySharedKey" -o tsv)
    TENANT_ID=$(az account show --query "tenantId" -o tsv)
    
    # Deploy using ARM template
    az deployment group create \
        --resource-group "$RESOURCE_GROUP_NAME" \
        --template-file "infrastructure/arm-template.json" \
        --parameters \
            logicAppName="$LOGIC_APP_NAME" \
            location="$LOCATION" \
            tenantId="$TENANT_ID" \
            workspaceResourceId="$WORKSPACE_RESOURCE_ID" \
            workspaceId="$WORKSPACE_ID" \
            workspaceKey="$WORKSPACE_KEY" \
            recurrenceFrequency="Hour" \
            recurrenceInterval=1
    
    if [ $? -eq 0 ]; then
        print_success "Logic App deployed successfully"
    else
        print_error "Failed to deploy Logic App"
        exit 1
    fi
}

# Function to configure managed identity permissions
configure_permissions() {
    print_info "Configuring managed identity permissions..."
    
    # Get Logic App managed identity principal ID
    PRINCIPAL_ID=$(az logicapp show --resource-group "$RESOURCE_GROUP_NAME" --name "$LOGIC_APP_NAME" --query "identity.principalId" -o tsv)
    
    if [ -z "$PRINCIPAL_ID" ]; then
        print_error "Failed to get Logic App managed identity principal ID"
        exit 1
    fi
    
    print_info "Logic App Principal ID: $PRINCIPAL_ID"
    
    # Get workspace resource ID
    WORKSPACE_RESOURCE_ID=$(az monitor log-analytics workspace show --resource-group "$RESOURCE_GROUP_NAME" --workspace-name "$WORKSPACE_NAME" --query "id" -o tsv)
    
    # Assign Log Analytics Contributor role
    az role assignment create \
        --assignee "$PRINCIPAL_ID" \
        --role "Log Analytics Contributor" \
        --scope "$WORKSPACE_RESOURCE_ID"
    
    if [ $? -eq 0 ]; then
        print_success "Log Analytics Contributor role assigned"
    else
        print_warning "Failed to assign Log Analytics Contributor role"
    fi
    
    print_warning "Manual configuration required for Office 365 Management API permissions:"
    print_info "1. Go to Azure AD > Enterprise Applications"
    print_info "2. Find your Logic App managed identity"
    print_info "3. Add API permissions for Office 365 Management APIs"
    print_info "4. Grant admin consent for the permissions"
}

# Function to validate deployment
validate_deployment() {
    print_info "Validating deployment..."
    
    # Check Logic App status
    LOGIC_APP_STATE=$(az logicapp show --resource-group "$RESOURCE_GROUP_NAME" --name "$LOGIC_APP_NAME" --query "state" -o tsv)
    
    if [ "$LOGIC_APP_STATE" = "Enabled" ]; then
        print_success "Logic App is enabled"
    else
        print_warning "Logic App state: $LOGIC_APP_STATE"
    fi
    
    # Check if custom table exists (this might take some time to appear)
    print_info "Custom table validation may take 5-10 minutes to reflect in queries"
    
    print_success "Deployment validation completed"
}

# Function to show deployment summary
show_summary() {
    print_header "Deployment Summary"
    echo "Subscription ID: $SUBSCRIPTION_ID"
    echo "Resource Group: $RESOURCE_GROUP_NAME"
    echo "Workspace: $WORKSPACE_NAME"
    echo "Logic App: $LOGIC_APP_NAME"
    echo "Location: $LOCATION"
    echo "Custom Table: $TABLE_NAME"
    echo ""
    print_info "Query to check ingested data:"
    echo "$TABLE_NAME | take 10"
}

# Function to show troubleshooting commands
show_troubleshooting() {
    print_header "Troubleshooting Commands"
    
    echo "# Check Logic App status"
    echo "az logicapp show --resource-group \"$RESOURCE_GROUP_NAME\" --name \"$LOGIC_APP_NAME\" --query \"state\""
    echo ""
    
    echo "# View Logic App runs"
    echo "az logicapp show --resource-group \"$RESOURCE_GROUP_NAME\" --name \"$LOGIC_APP_NAME\" --query \"definition\""
    echo ""
    
    echo "# Check workspace tables"
    echo "az monitor log-analytics workspace table list --resource-group \"$RESOURCE_GROUP_NAME\" --workspace-name \"$WORKSPACE_NAME\""
    echo ""
    
    echo "# View resource group resources"
    echo "az resource list --resource-group \"$RESOURCE_GROUP_NAME\" --output table"
    echo ""
    
    echo "# Check role assignments"
    echo "az role assignment list --resource-group \"$RESOURCE_GROUP_NAME\" --output table"
}

# Main execution
main() {
    case "${1:-deploy}" in
        "deploy")
            check_azure_cli
            azure_login
            create_resource_group
            validate_workspace
            create_custom_table
            deploy_logic_app
            configure_permissions
            validate_deployment
            show_summary
            ;;
        "troubleshoot")
            show_troubleshooting
            ;;
        "validate")
            check_azure_cli
            azure_login
            validate_workspace
            validate_deployment
            ;;
        *)
            echo "Usage: $0 [deploy|troubleshoot|validate]"
            echo "  deploy      - Full deployment (default)"
            echo "  troubleshoot - Show troubleshooting commands"
            echo "  validate    - Validate existing deployment"
            exit 1
            ;;
    esac
}

# Run main function with all arguments
main "$@"
