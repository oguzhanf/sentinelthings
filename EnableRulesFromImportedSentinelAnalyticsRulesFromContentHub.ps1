

$resourceGroupName = ""
$workspaceName = ""
$ruleTemplates = Get-AzSentinelAlertRuleTemplate -ResourceGroupName $resourceGroupName -WorkspaceName $workspaceName
$totalTemplates = $ruleTemplates.Count
$enabledCount = 0
$failedCount = 0
$failedRules = @()

Write-Output "Total number of templates: $totalTemplates"
$progress = 0

foreach ($template in $ruleTemplates) {
    $ruleName = $template.DisplayName -replace ' ', '_'
    $progress++
    Write-Progress -Activity "Processing templates" -Status "$progress of $totalTemplates" -PercentComplete (($progress / $totalTemplates) * 100)
    Write-Output "Creating and enabling rule from template: $ruleName"

    $params = @{
        ResourceGroupName     = $resourceGroupName
        WorkspaceName         = $workspaceName
        Kind                  = $template.Kind
        DisplayName           = $template.DisplayName
        Description           = $template.Description
        Severity              = $template.Severity
        Query                 = $template.Query
        Enabled               = $true
        Tactic                = $template.Tactic
        TriggerOperator       = $template.TriggerOperator
        TriggerThreshold      = $template.TriggerThreshold
        QueryFrequency        = $template.QueryFrequency
        QueryPeriod           = $template.QueryPeriod
    }

    if ($template.SuppressionDuration -ne $null) {
        $params.SuppressionDuration = $template.SuppressionDuration
    }

    if ($template.EntityMappings -ne $null) {
        $params.EntityMappings = $template.EntityMappings
    }

    try {
        New-AzSentinelAlertRule @params
        $enabledCount++
    } catch {
        Write-Output "Failed to create rule $ruleName because one of the referenced tables does not exist in the schema."
        $failedCount++
        $failedRules += $ruleName
    }
}

Write-Output "All alert rule templates have been processed."
Write-Output "Total enabled rules: $enabledCount"
Write-Output "Total failed rules: $failedCount"
if ($failedCount -gt 0) {
    Write-Output "Failed rules:"
    $failedRules | ForEach-Object { Write-Output $_ }
}
