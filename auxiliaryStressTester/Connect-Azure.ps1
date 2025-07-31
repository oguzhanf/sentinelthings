# Azure Authentication Script with Device Code Flow
# Run this once to authenticate and stay logged in

param(
    [Parameter(Mandatory = $true)]
    [string]$SubscriptionId
)

Write-Host "=== Azure Authentication Setup ===" -ForegroundColor Cyan
Write-Host "This will authenticate you to Azure using device code flow." -ForegroundColor Yellow
Write-Host "You'll only need to do this once per PowerShell session." -ForegroundColor Yellow

try {
    # Check if already authenticated
    $context = Get-AzContext
    if ($context -and $context.Subscription.Id -eq $SubscriptionId) {
        Write-Host "Already authenticated to subscription: $SubscriptionId" -ForegroundColor Green
        Write-Host "Account: $($context.Account.Id)" -ForegroundColor Cyan
        Write-Host "Tenant: $($context.Tenant.Id)" -ForegroundColor Cyan
        return
    }

    # Connect using device code flow
    Write-Host "`nConnecting to Azure..." -ForegroundColor Yellow
    Write-Host "A browser window will open for authentication." -ForegroundColor Cyan
    
    $account = Connect-AzAccount -UseDeviceAuthentication -SubscriptionId $SubscriptionId
    
    if ($account) {
        Write-Host "`n✅ Successfully authenticated!" -ForegroundColor Green
        Write-Host "Account: $($account.Context.Account.Id)" -ForegroundColor Cyan
        Write-Host "Subscription: $($account.Context.Subscription.Name)" -ForegroundColor Cyan
        Write-Host "Tenant: $($account.Context.Tenant.Id)" -ForegroundColor Cyan
        
        # Set the context
        Set-AzContext -SubscriptionId $SubscriptionId | Out-Null
        
        Write-Host "`n🎉 You're now ready to run the Sentinel automation scripts!" -ForegroundColor Green
        Write-Host "This authentication will persist for this PowerShell session." -ForegroundColor Yellow
    } else {
        Write-Host "❌ Authentication failed" -ForegroundColor Red
        exit 1
    }
}
catch {
    Write-Host "❌ Error during authentication: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
