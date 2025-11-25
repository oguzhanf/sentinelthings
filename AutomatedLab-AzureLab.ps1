<#
.SYNOPSIS
AutomatedLab Azure lab: 2x WS2025 DCs, 5 Windows member servers, 2 Debian 12, 2 Win11, 2 Win10.
NOTE: This will deploy 13 Azure VMs. Stop or remove the lab when you are done to avoid unnecessary cost.

PREREQUISITES
- AutomatedLab module installed (Install-Module AutomatedLab -Scope CurrentUser)
- You are signed in to Azure, or will sign in when Add-LabAzureSubscription prompts
- A subscription with quota for 13 small VMs in the chosen region

NOTE ON LOAD BALANCER
AutomatedLab Azure labs use a shared Azure Load Balancer by design for outbound connectivity and RDP/WinRM NAT.
This script does not explicitly create any additional load balancers.
#>

param (
    [string]$LabName    = 'AzureAdLab01',
    [string]$Location   = 'West Europe',   # Azure region display name used by AutomatedLab
    [string]$DomainName = 'labs.uaesecsec.com'
)

# Ensure the folder where AutomatedLab was actually installed is on PSModulePath (handles OneDrive redirection)
try {
	$paths  = $env:PSModulePath -split ';'
	$myDocs = [Environment]::GetFolderPath('MyDocuments')

	$legacyWinPsModules = Join-Path $myDocs 'WindowsPowerShell\Modules'
	if (Test-Path $legacyWinPsModules) {
		if ($paths -notcontains $legacyWinPsModules) {
			$paths += $legacyWinPsModules
		}
	}

	$pwshModules = Join-Path $myDocs 'PowerShell\Modules'
	if (Test-Path $pwshModules) {
		if ($paths -notcontains $pwshModules) {
			$paths += $pwshModules
		}
	}

	$env:PSModulePath = ($paths -join ';')
}
catch {
	Write-Warning "Failed to normalize PSModulePath for AutomatedLab: $($_.Exception.Message)"
}

# Import core AutomatedLab modules directly (work around AutomatedLab meta-module / Recipe import issue)
$alModules = @(
    'AutomatedLab.Common'
    'AutomatedLabCore'
    'AutomatedLabDefinition'
    'AutomatedLabNotifications'
    'AutomatedLabUnattended'
    'AutomatedLabWorker'
)
foreach ($m in $alModules) {
    Import-Module $m -ErrorAction Stop
}

# Define the lab and default virtualization engine (Azure)
New-LabDefinition -Name $LabName -DefaultVirtualizationEngine Azure

# Installation / domain admin credential used across the lab
Set-LabInstallationCredential -Username 'UAESecSE' -Password 'Password.1'

# Attach / select Azure subscription in the chosen region (interactive, you choose tenant/sub)
$selectedSub = $null
try {
	Import-Module Az.Accounts -ErrorAction Stop

	# Work only with a fresh in-process Az context to avoid cached wrong tenants
	try {
		Disable-AzContextAutosave -Scope Process -ErrorAction SilentlyContinue | Out-Null
	} catch {}
	try {
		Clear-AzContext -Scope Process -Force -ErrorAction SilentlyContinue | Out-Null
	} catch {}

	Write-Host "An Azure sign-in window will open. Use the account/tenant that owns the subscription for this lab." -ForegroundColor Yellow
	Connect-AzAccount | Out-Null

	$subs = Get-AzSubscription
	if (-not $subs -or $subs.Count -eq 0) {
		throw "No Azure subscriptions found for the signed-in account."
	}

	Write-Host "Available Azure subscriptions:" -ForegroundColor Cyan
	$index = 1
	foreach ($s in $subs) {
		Write-Host ("[{0}] {1}  (Id: {2}, Tenant: {3})" -f $index, $s.Name, $s.Id, $s.TenantId)
		$index++
	}

	$selection = Read-Host "Enter the number of the subscription you want to use for this lab"
	if (-not ($selection -as [int]) -or $selection -lt 1 -or $selection -gt $subs.Count) {
		throw "Invalid subscription selection '$selection'."
	}

	$selectedSub = $subs[[int]$selection - 1]
	Write-Host ("Using subscription '{0}' ({1}) in tenant {2}" -f $selectedSub.Name, $selectedSub.Id, $selectedSub.TenantId) -ForegroundColor Green
	Set-AzContext -SubscriptionId $selectedSub.Id -TenantId $selectedSub.TenantId | Out-Null
}
catch {
	Write-Warning "Could not run interactive Azure subscription selection via Az.Accounts. Falling back to AutomatedLab's default Add-LabAzureSubscription behavior. Error: $($_.Exception.Message)"
}

if ($selectedSub) {
	Add-LabAzureSubscription -SubscriptionId $selectedSub.Id -DefaultLocationName $Location | Out-Null
}
else {
	Add-LabAzureSubscription -DefaultLocationName $Location | Out-Null
}

# Lab AD domain definition
Add-LabDomainDefinition -Name $DomainName -AdminUser 'UAESecSE' -AdminPassword 'Password.1'

# Single Azure VNet for all machines; DNS points to the DC IPs for domain joins
$labVnetName = 'AzLabVNet'
Add-LabVirtualNetworkDefinition -Name $labVnetName `
    -AddressSpace '10.34.0.0/16' `
    -VirtualizationEngine Azure `
    -AzureProperties @{
        SubnetName         = 'Subnet1'
        SubnetAddressPrefix = 24
        LocationName       = $Location
        DnsServers         = '10.34.0.4,10.34.0.5'   # Planned IPs for TENGRI-DC01/TENGRI-DC02
    }

# Resolve Azure images dynamically for the chosen region (cost-effective, latest SKUs)
$azureOs = Get-LabAvailableOperatingSystem -Azure -Location $Location -UseOnlyCache

$ws2025 = $azureOs | Where-Object { $_.OperatingSystemName -like 'Windows Server 2025*' } | Select-Object -First 1
if (-not $ws2025) { throw "Windows Server 2025 image not found in region '$Location'." }

$ws2022 = $azureOs | Where-Object { $_.OperatingSystemName -like 'Windows Server 2022*' } | Select-Object -First 1
if (-not $ws2022) { throw "Windows Server 2022 image not found in region '$Location'." }

$win11 = $azureOs | Where-Object { $_.OperatingSystemName -like 'Windows 11*' } | Select-Object -First 1
if (-not $win11) { throw "Windows 11 image not found in region '$Location'." }

$win10 = $azureOs | Where-Object { $_.OperatingSystemName -like 'Windows 10*' } | Select-Object -First 1
if (-not $win10) { throw "Windows 10 image not found in region '$Location'." }

$debian12 = $azureOs | Where-Object { $_.OperatingSystemName -like 'Debian*12*' } | Select-Object -First 1
if (-not $debian12) { throw "Debian 12 image not found in region '$Location'." }

# VM size recommendations (B-series are cheap and fine for lab workloads)
$sizeDcAndServers   = 'Standard_B2ms' # 2 vCPU, 8 GiB RAM for DCs and servers
$sizeWindowsClients = 'Standard_B2s'  # 2 vCPU, 4 GiB RAM for Windows clients
$sizeDebianGui      = 'Standard_B2ms' # A bit more RAM for GUI on Debian

# --- Domain controllers (Windows Server 2025, Turkic mythology) ---
Add-LabMachineDefinition -Name 'TENGRI-DC01' `
    -Roles RootDC `
    -DomainName $DomainName `
    -OperatingSystem $ws2025 `
    -Network $labVnetName `
    -IpAddress '10.34.0.4/24' `
    -AzureRoleSize $sizeDcAndServers

Add-LabMachineDefinition -Name 'TENGRI-DC02' `
    -Roles DC `
    -DomainName $DomainName `
    -OperatingSystem $ws2025 `
    -Network $labVnetName `
    -IpAddress '10.34.0.5/24' `
    -AzureRoleSize $sizeDcAndServers

# --- Member servers (2x WS2025, 3x WS2022) ---
Add-LabMachineDefinition -Name 'ERGENEKON-SRV01' `
    -DomainName $DomainName -IsDomainJoined `
    -OperatingSystem $ws2025 `
    -Network $labVnetName `
    -AzureRoleSize $sizeDcAndServers

Add-LabMachineDefinition -Name 'ERGENEKON-SRV02' `
    -DomainName $DomainName -IsDomainJoined `
    -OperatingSystem $ws2025 `
    -Network $labVnetName `
    -AzureRoleSize $sizeDcAndServers

1..3 | ForEach-Object {
    Add-LabMachineDefinition -Name ("BOZKURT-SRV0{0}" -f $_) `
        -DomainName $DomainName -IsDomainJoined `
        -OperatingSystem $ws2022 `
        -Network $labVnetName `
        -AzureRoleSize $sizeDcAndServers
}

# --- Windows clients (2x Windows 11, 2x Windows 10) ---
1..2 | ForEach-Object {
    Add-LabMachineDefinition -Name ("UMAY11-0{0}" -f $_) `
        -DomainName $DomainName -IsDomainJoined `
        -OperatingSystem $win11 `
        -Network $labVnetName `
        -AzureRoleSize $sizeWindowsClients
}

1..2 | ForEach-Object {
    Add-LabMachineDefinition -Name ("ERLIK10-0{0}" -f $_) `
        -DomainName $DomainName -IsDomainJoined `
        -OperatingSystem $win10 `
        -Network $labVnetName `
        -AzureRoleSize $sizeWindowsClients
}

# --- Debian-based Linux servers with GUI (Debian 12) ---
# These will be Debian 12 servers. A lightweight desktop can be installed post-deployment, e.g.:
#   sudo apt-get update
#   sudo DEBIAN_FRONTEND=noninteractive apt-get install -y task-gnome-desktop
1..2 | ForEach-Object {
    Add-LabMachineDefinition -Name ("ASENA-LNX0{0}" -f $_) `
        -OperatingSystem $debian12 `
        -Network $labVnetName `
        -AzureRoleSize $sizeDebianGui `
        -Notes @{ Purpose = 'Debian 12 server with desktop environment'; }
}

# Deploy the lab to Azure (this can take quite a while)
Install-Lab

# Ensure Active Directory is fully ready before you start using the lab
Wait-LabADReady -ComputerName 'TENGRI-DC01','TENGRI-DC02' -TimeoutInMinutes 60

Show-LabDeploymentSummary

