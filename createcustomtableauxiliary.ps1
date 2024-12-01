# Connect to Azure
Connect-AzAccount




$PayLoad = @{
    properties = @{

        schema = @{
            name = "CustomTable_CL"
            columns = @(
                        @{
                            name = "TimeGenerated"
                            type = "datetime"
                         }
                        @{
                            name = "properties"
                            type = "string"
                         }
                         @{
                            name = "Computer"
                            type = "string"
                         }
                        )
        }
                totalRetentionInDays = 365
        plan = "Auxiliary"

    }
            }
$PayLoadJson = $PayLoad | ConvertTo-Json -Depth 20

$URI = "/subscriptions/SUBID/resourcegroups/RGNAME/providers/microsoft.operationalinsights/workspaces/WKSNAME/tables/CustomTable_CL?api-version=2023-01-01-preview"

Invoke-AzRestMethod -Path $URI -Method PUT -Payload $PayLoadJson
