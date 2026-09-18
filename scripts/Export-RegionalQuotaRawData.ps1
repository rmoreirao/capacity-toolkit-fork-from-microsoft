<#
.SYNOPSIS
    Collect a compact, shareable three-region quota and availability-zone data package.

.DESCRIPTION
    This read-only wrapper is intended for a customer with:
      * a primary region whose current usage is useful as a sizing reference,
      * an existing DR region whose quota should be matched, and
      * a target DR region that may need quota increases.

    By default it scans every enabled subscription in the CURRENT Azure tenant. It collects:
      * Compute usage and limits from `az vm list-usage`.
      * Network, App Service, Storage, Azure SQL and Cosmos DB data from the toolkit collectors.
      * VM / VMSS / AKS SKUs currently used in the primary region.
      * Regional and logical-zone availability for those SKUs in all three regions.
      * Per-subscription logical-to-physical availability-zone mappings.

    The service-specific quota rows are normalized into one CSV. Service-specific fields that do
    not fit the common schema are retained as compact JSON in the Details column.

    Azure does not expose one universal quota API for every service. This script covers the service
    areas implemented by this toolkit; informational inventory and documented ceilings are clearly
    marked so they are not mistaken for adjustable quota.

    The script does not request quota or modify Azure resources. Some underlying collectors change
    the active Azure CLI subscription while reading data, so the original subscription is restored
    before the script exits.

.PARAMETER PrimaryRegion
    Main workload region used for current SKU discovery and usage reference. Default: westeurope.

.PARAMETER ExistingDrRegion
    Existing DR region whose quota is intended to be matched. Default: northeurope.

.PARAMETER TargetDrRegion
    Target DR region being evaluated. Default: germanywestcentral.

.PARAMETER SubscriptionIds
    Optional explicit subscription IDs. If omitted, -SubscriptionCsv is used; if both are omitted,
    every enabled subscription in the current Azure tenant is scanned.

.PARAMETER SubscriptionCsv
    Optional CSV with a SubId, subscriptionId or id column and an optional Name column.

.PARAMETER OutDir
    Output directory. The default is a timestamped folder under output/.

.PARAMETER SkipArchive
    Do not create a ZIP file next to the output directory.

.EXAMPLE
    .\scripts\Export-RegionalQuotaRawData.ps1

    Scan all enabled subscriptions in the current tenant for West Europe, North Europe and
    Germany West Central, then create a compact output folder and ZIP archive.

.EXAMPLE
    .\scripts\Export-RegionalQuotaRawData.ps1 `
        -SubscriptionCsv .\customer-subscriptions.csv `
        -OutDir .\output\customer-quota-raw
#>
[CmdletBinding()]
param(
    [ValidatePattern('^[a-z0-9]+$')]
    [string]   $PrimaryRegion = 'westeurope',
    [ValidatePattern('^[a-z0-9]+$')]
    [string]   $ExistingDrRegion = 'northeurope',
    [ValidatePattern('^[a-z0-9]+$')]
    [string]   $TargetDrRegion = 'germanywestcentral',
    [string[]] $SubscriptionIds,
    [string]   $SubscriptionCsv,
    [string]   $OutDir,
    [switch]   $SkipArchive
)

. "$PSScriptRoot\Common.ps1"

$tenantId = Assert-AzLogin
$originalAccount = az account show -o json 2>$null | ConvertFrom-Json
if (-not $originalAccount) { throw 'Unable to read the current Azure CLI account.' }

$regions = @($PrimaryRegion, $ExistingDrRegion, $TargetDrRegion) |
    Where-Object { $_ } |
    ForEach-Object { $_.ToLower() } |
    Select-Object -Unique

if ($regions.Count -ne 3) {
    throw 'PrimaryRegion, ExistingDrRegion and TargetDrRegion must be three distinct Azure regions.'
}

if (-not $OutDir) {
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $OutDir = Join-Path (Get-DefaultOutDir) "regional-quota-raw-$stamp"
}

$OutDir = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutDir)
New-Item -ItemType Directory -Path $OutDir -Force | Out-Null

# Remove only outputs owned by this wrapper when an explicit directory is reused. Unrelated files in
# the directory are preserved.
$ownedOutputNames = @(
    'regional-quota-data.csv',
    'primary-region-used-skus.csv',
    'sku-availability-by-region.csv',
    'availability-zone-mappings.csv',
    'collection-summary.json',
    'collection-errors.csv'
)
foreach ($name in $ownedOutputNames) {
    $ownedPath = Join-Path $OutDir $name
    if (Test-Path $ownedPath) { Remove-Item $ownedPath -Force }
}

# Intermediate files from the existing toolkit collectors are kept in one known subdirectory and
# removed after they have been normalized into the compact customer-facing outputs.
$workDir = Join-Path $OutDir '_collector-work'
if (Test-Path $workDir) { Remove-Item $workDir -Recurse -Force }
New-Item -ItemType Directory -Path $workDir -Force | Out-Null

$scopeCsv = Join-Path $workDir 'subscription-scope.csv'
$quotaRows = @()
$collectionErrors = @()

function Add-CollectionError {
    param(
        [string]$Collector,
        [string]$Subscription,
        [string]$SubscriptionId,
        [string]$Region,
        [string]$Message
    )
    $script:collectionErrors += [pscustomobject][ordered]@{
        Collector       = $Collector
        Subscription    = $Subscription
        SubscriptionId  = $SubscriptionId
        Region          = $Region
        Error            = $Message
    }
}

function Add-QuotaRow {
    param(
        [string]$Service,
        [string]$Subscription,
        [string]$SubscriptionId,
        [string]$Region,
        [string]$Scope,
        [string]$Resource,
        [string]$MetricId,
        [string]$Metric,
        $Used,
        $Limit,
        $Available,
        [string]$Unit,
        [bool]$IsQuota,
        [bool]$IsInformational,
        [string]$Source,
        $Details
    )

    $detailText = ''
    if ($null -ne $Details) {
        $detailText = $Details | ConvertTo-Json -Compress -Depth 5
    }

    $script:quotaRows += [pscustomobject][ordered]@{
        Service          = $Service
        Subscription     = $Subscription
        SubscriptionId   = $SubscriptionId
        Region           = $Region
        Scope            = $Scope
        Resource         = $Resource
        MetricId         = $MetricId
        Metric           = $Metric
        Used             = $Used
        Limit            = $Limit
        Available        = $Available
        Unit             = $Unit
        IsQuota          = $IsQuota
        IsInformational  = $IsInformational
        Source           = $Source
        Details          = $detailText
    }
}

function Invoke-Collector {
    param(
        [string]$Name,
        [scriptblock]$Action
    )
    Write-Host "`n=== $Name ===" -ForegroundColor Magenta
    try {
        & $Action
        if (-not $?) { throw "$Name returned an unsuccessful status." }
    } catch {
        Add-CollectionError -Collector $Name -Message $_.Exception.Message
        Write-Warning "$Name failed: $($_.Exception.Message)"
    }
}

function Invoke-ResourceGraph {
    param(
        [string]$Query,
        [string]$SubscriptionId,
        [string]$Collector
    )

    $result = @()
    $skip = 0
    do {
        $response = az graph query `
            --subscriptions $SubscriptionId `
            -q $Query `
            --first 1000 `
            --skip $skip `
            --only-show-errors `
            -o json 2>&1

        if ($LASTEXITCODE -ne 0) {
            Add-CollectionError `
                -Collector $Collector `
                -SubscriptionId $SubscriptionId `
                -Region $PrimaryRegion `
                -Message (($response -join ' ').Trim())
            return @()
        }

        try {
            $batch = ($response -join "`n") | ConvertFrom-Json
        } catch {
            Add-CollectionError `
                -Collector $Collector `
                -SubscriptionId $SubscriptionId `
                -Region $PrimaryRegion `
                -Message "Invalid Resource Graph response: $($_.Exception.Message)"
            return @()
        }

        if ($batch.data) { $result += @($batch.data) }
        $skip += 1000
        $total = [int]$batch.total_records
    } while ($batch.data -and $batch.data.Count -gt 0 -and $result.Count -lt $total)

    return $result
}

try {
    # Step 1: Freeze the subscription scope so every collector sees the same customer subscriptions.
    if ($SubscriptionIds -and $SubscriptionIds.Count) {
        $subscriptions = @($SubscriptionIds | ForEach-Object {
            [pscustomobject]@{ Name = $_; SubId = $_ }
        })
    } elseif ($SubscriptionCsv) {
        $subscriptions = @(Resolve-Subscriptions -SubscriptionCsv $SubscriptionCsv)
    } else {
        # `az account list` can contain cached subscriptions from other tenants. Defaulting to the
        # current tenant avoids an implicit tenant switch during a customer collection.
        $accountListJson = az account list --all -o json 2>$null
        if ($LASTEXITCODE -ne 0) { throw 'Unable to enumerate Azure subscriptions.' }
        $accountList = ($accountListJson -join "`n") | ConvertFrom-Json
        $subscriptions = @(
            $accountList |
                Where-Object { $_.state -eq 'Enabled' -and $_.tenantId -eq $tenantId } |
                Sort-Object name |
                ForEach-Object { [pscustomobject]@{ Name = $_.name; SubId = $_.id } }
        )
    }

    if (-not $subscriptions.Count) { throw 'No subscriptions were resolved for collection.' }
    $subscriptions | Export-Csv $scopeCsv -NoTypeInformation -Encoding UTF8

    Write-Host "`nCollecting $($subscriptions.Count) subscription(s) across: $($regions -join ', ')" -ForegroundColor Cyan
    Write-Host "Output: $OutDir" -ForegroundColor Cyan

    # Step 2: Compute exposes quota through its own regional usage endpoint. Keep every returned
    # metric, including Total Regional vCPUs, Spot vCPUs and all VM-family quota rows.
    foreach ($subscription in $subscriptions) {
        foreach ($region in $regions) {
            Write-Progress -Activity 'Compute quota and usage' `
                -Status "$($subscription.Name) / $region"

            $response = az vm list-usage `
                --subscription $subscription.SubId `
                --location $region `
                --only-show-errors `
                -o json 2>&1

            if ($LASTEXITCODE -ne 0) {
                Add-CollectionError `
                    -Collector 'Compute quota' `
                    -Subscription $subscription.Name `
                    -SubscriptionId $subscription.SubId `
                    -Region $region `
                    -Message (($response -join ' ').Trim())
                continue
            }

            try {
                $usageRows = @(($response -join "`n") | ConvertFrom-Json)
                foreach ($usage in $usageRows) {
                    $used = [long]$usage.currentValue
                    $limit = [long]$usage.limit
                    Add-QuotaRow `
                        -Service 'Compute' `
                        -Subscription $subscription.Name `
                        -SubscriptionId $subscription.SubId `
                        -Region $region `
                        -Scope 'SubscriptionRegion' `
                        -MetricId $usage.name.value `
                        -Metric $usage.name.localizedValue `
                        -Used $used `
                        -Limit $limit `
                        -Available ($limit - $used) `
                        -Unit $usage.unit `
                        -IsQuota $true `
                        -IsInformational $false `
                        -Source 'Microsoft.Compute/locations/usages'
                }
            } catch {
                Add-CollectionError `
                    -Collector 'Compute quota' `
                    -Subscription $subscription.Name `
                    -SubscriptionId $subscription.SubId `
                    -Region $region `
                    -Message "Invalid usage response: $($_.Exception.Message)"
            }
        }
    }
    Write-Progress -Activity 'Compute quota and usage' -Completed

    # Step 3: Run each non-compute collector once for all three regions. The temporary CSVs retain
    # their native schemas until they are copied into the normalized regional-quota-data.csv.
    $networkCsv = Join-Path $workDir 'network.csv'
    $appServiceCsv = Join-Path $workDir 'appservice.csv'
    $storageCsv = Join-Path $workDir 'storage.csv'
    $paasCsv = Join-Path $workDir 'paas.csv'

    Invoke-Collector 'Network quota' {
        & "$PSScriptRoot\Get-NetworkQuota.ps1" `
            -Location $regions `
            -SubscriptionCsv $scopeCsv `
            -OutPath $networkCsv
    }
    Invoke-Collector 'App Service quota' {
        & "$PSScriptRoot\Get-AppServiceQuota.ps1" `
            -Location $regions `
            -SubscriptionCsv $scopeCsv `
            -OutPath $appServiceCsv
    }
    Invoke-Collector 'Storage quota' {
        & "$PSScriptRoot\Get-StorageQuota.ps1" `
            -Location $regions `
            -IncludeDiskCapacityInventory `
            -SubscriptionCsv $scopeCsv `
            -OutPath $storageCsv
    }
    Invoke-Collector 'PaaS quota' {
        & "$PSScriptRoot\Get-PaasQuota.ps1" `
            -Service All `
            -Location $regions `
            -IncludeCosmosThroughputInventory `
            -SubscriptionCsv $scopeCsv `
            -OutPath $paasCsv
    }

    if (Test-Path $networkCsv) {
        foreach ($row in @(Import-Csv $networkCsv)) {
            $informational = ($row.IsUnbounded -eq 'True' -or $row.PerResourceScope -eq 'True')
            Add-QuotaRow `
                -Service 'Network' `
                -Subscription $row.Subscription `
                -SubscriptionId $row.SubscriptionId `
                -Region $row.Region `
                -Scope 'SubscriptionRegion' `
                -MetricId $row.MetricId `
                -Metric $row.Metric `
                -Used $row.Used `
                -Limit $row.Limit `
                -Available $row.Available `
                -Unit $row.Unit `
                -IsQuota (-not $informational) `
                -IsInformational $informational `
                -Source 'Microsoft.Network/locations/usages' `
                -Details ([ordered]@{
                    IsUnbounded = $row.IsUnbounded
                    PerResourceScope = $row.PerResourceScope
                    NearLimit = $row.NearLimit
                    AtLimit = $row.AtLimit
                    Notes = $row.Notes
                })
        }
    }

    if (Test-Path $appServiceCsv) {
        foreach ($row in @(Import-Csv $appServiceCsv)) {
            $isQuota = ($row.IsTrueQuota -eq 'True')
            $resource = $row.AppServicePlan
            Add-QuotaRow `
                -Service 'AppService' `
                -Subscription $row.Subscription `
                -SubscriptionId $row.SubscriptionId `
                -Region $row.Region `
                -Scope $row.Scope `
                -Resource $resource `
                -MetricId $row.MetricId `
                -Metric $row.Metric `
                -Used $row.Used `
                -Limit $row.Limit `
                -Available $row.Available `
                -Unit $row.Unit `
                -IsQuota $isQuota `
                -IsInformational (-not $isQuota) `
                -Source $row.MetricSource `
                -Details ([ordered]@{
                    ResourceGroup = $row.ResourceGroup
                    Sku = $row.Sku
                    Tier = $row.Tier
                    Capacity = $row.Capacity
                    LimitBasis = $row.LimitBasis
                    NearLimit = $row.NearLimit
                    AtLimit = $row.AtLimit
                    Status = $row.Status
                    Error = $row.Error
                })
        }
    }

    if (Test-Path $storageCsv) {
        foreach ($row in @(Import-Csv $storageCsv)) {
            $isQuota = ($row.IsQuota -eq 'True')
            Add-QuotaRow `
                -Service 'Storage' `
                -Subscription $row.Subscription `
                -SubscriptionId $row.SubscriptionId `
                -Region $row.Region `
                -Scope 'SubscriptionRegion' `
                -Resource $row.DiskSku `
                -MetricId $row.Metric `
                -Metric $row.Metric `
                -Used $row.Used `
                -Limit $row.Limit `
                -Available $row.Available `
                -Unit $row.Unit `
                -IsQuota $isQuota `
                -IsInformational (-not $isQuota) `
                -Source 'Storage quota and inventory collectors' `
                -Details ([ordered]@{
                    Flag = $row.Flag
                    Notes = $row.Notes
                })
        }
    }

    if (Test-Path $paasCsv) {
        foreach ($row in @(Import-Csv $paasCsv)) {
            $informational = ($row.IsInformational -eq 'True')
            Add-QuotaRow `
                -Service $row.Service `
                -Subscription $row.Subscription `
                -SubscriptionId $row.SubscriptionId `
                -Region $row.Region `
                -Scope 'SubscriptionRegionOrResource' `
                -Resource $row.Resource `
                -MetricId $row.Metric `
                -Metric $row.Metric `
                -Used $row.Used `
                -Limit $row.Limit `
                -Available $row.Available `
                -Unit $row.Unit `
                -IsQuota (-not $informational) `
                -IsInformational $informational `
                -Source 'PaaS quota and inventory collectors' `
                -Details ([ordered]@{
                    Flag = $row.Flag
                    Notes = $row.Notes
                })
        }
    }

    $quotaPath = Join-Path $OutDir 'regional-quota-data.csv'
    $quotaRows |
        Sort-Object Subscription, Region, Service, MetricId |
        Export-Csv $quotaPath -NoTypeInformation -Encoding UTF8

    # Step 4: Inventory VM, VMSS and AKS pool SKUs specifically in the primary region. This is kept
    # separate from quota usage because Azure reports compute quota by family, not by individual SKU.
    az extension show --name resource-graph -o none 2>$null
    if ($LASTEXITCODE -ne 0) {
        az extension add --name resource-graph -o none 2>$null
    }

    $usedSkuRows = @()
    foreach ($subscription in $subscriptions) {
        $vmQuery = "resources | where type =~ 'microsoft.compute/virtualmachines' | where location =~ '$PrimaryRegion' | project subscriptionId, resourceGroup, name, location, sku=tostring(properties.hardwareProfile.vmSize), zones"
        $vmssQuery = "resources | where type =~ 'microsoft.compute/virtualmachinescalesets' | where location =~ '$PrimaryRegion' | project subscriptionId, resourceGroup, name, location, sku=tostring(sku.name), instances=toint(sku.capacity), zones"
        $aksQuery = "resources | where type =~ 'microsoft.containerservice/managedclusters' | where location =~ '$PrimaryRegion' | mv-expand pool=properties.agentPoolProfiles | project subscriptionId, resourceGroup, name, location, poolName=tostring(pool['name']), sku=tostring(pool['vmSize']), instances=toint(pool['count']), maxCount=toint(pool['maxCount']), zones=pool['availabilityZones']"

        $vmRows = @(Invoke-ResourceGraph `
            -Query $vmQuery `
            -SubscriptionId $subscription.SubId `
            -Collector 'Primary-region VM inventory')
        foreach ($row in $vmRows) {
            $usedSkuRows += [pscustomobject][ordered]@{
                Subscription    = $subscription.Name
                SubscriptionId  = $subscription.SubId
                ResourceType    = 'VirtualMachine'
                ResourceGroup   = $row.resourceGroup
                ResourceName    = $row.name
                PoolName        = ''
                Region          = $row.location
                Sku             = $row.sku
                QuotaFamily     = ''
                InstanceCount   = 1
                MaxCount        = ''
                Zones           = (@($row.zones) -join ',')
            }
        }

        $vmssRows = @(Invoke-ResourceGraph `
            -Query $vmssQuery `
            -SubscriptionId $subscription.SubId `
            -Collector 'Primary-region VMSS inventory')
        foreach ($row in $vmssRows) {
            $usedSkuRows += [pscustomobject][ordered]@{
                Subscription    = $subscription.Name
                SubscriptionId  = $subscription.SubId
                ResourceType    = 'VirtualMachineScaleSet'
                ResourceGroup   = $row.resourceGroup
                ResourceName    = $row.name
                PoolName        = ''
                Region          = $row.location
                Sku             = $row.sku
                QuotaFamily     = ''
                InstanceCount   = $row.instances
                MaxCount        = ''
                Zones           = (@($row.zones) -join ',')
            }
        }

        $aksRows = @(Invoke-ResourceGraph `
            -Query $aksQuery `
            -SubscriptionId $subscription.SubId `
            -Collector 'Primary-region AKS pool inventory')
        foreach ($row in $aksRows) {
            $usedSkuRows += [pscustomobject][ordered]@{
                Subscription    = $subscription.Name
                SubscriptionId  = $subscription.SubId
                ResourceType    = 'AksNodePool'
                ResourceGroup   = $row.resourceGroup
                ResourceName    = $row.name
                PoolName        = $row.poolName
                Region          = $row.location
                Sku             = $row.sku
                QuotaFamily     = ''
                InstanceCount   = $row.instances
                MaxCount        = $row.maxCount
                Zones           = (@($row.zones) -join ',')
            }
        }
    }

    # Map each discovered SKU to its compute quota family. Family mapping is stable, while quota
    # limits and SKU restrictions remain subscription-specific elsewhere in the package.
    $familyMap = @{}
    foreach ($subscription in $subscriptions) {
        try {
            $catalogue = @(Get-ComputeSkus -SubId $subscription.SubId -Location $PrimaryRegion)
            foreach ($sku in $catalogue) {
                if ($sku.resourceType -eq 'virtualMachines' -and $sku.name -and $sku.family) {
                    $familyMap[$sku.name.ToLower()] = $sku.family
                }
            }
            if ($familyMap.Count) { break }
        } catch {
            Add-CollectionError `
                -Collector 'Compute SKU family mapping' `
                -Subscription $subscription.Name `
                -SubscriptionId $subscription.SubId `
                -Region $PrimaryRegion `
                -Message $_.Exception.Message
        }
    }

    foreach ($row in $usedSkuRows) {
        if ($row.Sku -and $familyMap.ContainsKey($row.Sku.ToLower())) {
            $row.QuotaFamily = $familyMap[$row.Sku.ToLower()]
        }
    }

    $usedSkuPath = Join-Path $OutDir 'primary-region-used-skus.csv'
    if ($usedSkuRows.Count) {
        $usedSkuRows |
            Sort-Object Subscription, ResourceType, ResourceGroup, ResourceName, PoolName |
            Export-Csv $usedSkuPath -NoTypeInformation -Encoding UTF8
    } else {
        'Subscription,SubscriptionId,ResourceType,ResourceGroup,ResourceName,PoolName,Region,Sku,QuotaFamily,InstanceCount,MaxCount,Zones' |
            Set-Content $usedSkuPath -Encoding UTF8
    }

    # Step 5: For every discovered workload SKU, retain subscription-specific regional enablement
    # and logical-zone availability. Quota itself is regional; this is the separate placement check.
    $skuAvailability = @()
    $skus = @($usedSkuRows | Where-Object { $_.Sku } | Select-Object -ExpandProperty Sku -Unique)
    if ($skus.Count) {
        foreach ($region in $regions) {
            $regionPath = Join-Path $workDir "sku-availability-$region.csv"
            Invoke-Collector "SKU availability: $region" {
                & "$PSScriptRoot\Scan-SkuEnablement.ps1" `
                    -Location $region `
                    -Skus $skus `
                    -SubscriptionCsv $scopeCsv `
                    -OutPath $regionPath
            }
            if (Test-Path $regionPath) {
                $skuAvailability += Import-Csv $regionPath |
                    Select-Object @{Name='Region';Expression={$region}}, *
            }
        }
    }

    $skuAvailabilityPath = Join-Path $OutDir 'sku-availability-by-region.csv'
    if ($skuAvailability.Count) {
        $skuAvailability | Export-Csv $skuAvailabilityPath -NoTypeInformation -Encoding UTF8
    } else {
        'Region,Name,SubId' | Set-Content $skuAvailabilityPath -Encoding UTF8
    }

    # Step 6: Logical zone numbers are subscription-specific. Capture their physical mapping for
    # each region so zone 1 is never assumed to represent the same datacentre across subscriptions.
    $zoneMappings = @()
    foreach ($region in $regions) {
        $regionPath = Join-Path $workDir "zone-mapping-$region.csv"
        Invoke-Collector "Zone mapping: $region" {
            & "$PSScriptRoot\Get-ZoneMappings.ps1" `
                -Location $region `
                -SubscriptionCsv $scopeCsv `
                -OutPath $regionPath
        }
        if (Test-Path $regionPath) {
            $zoneMappings += Import-Csv $regionPath |
                Select-Object @{Name='Region';Expression={$region}}, *
        }
    }

    $zoneMappingsPath = Join-Path $OutDir 'availability-zone-mappings.csv'
    if ($zoneMappings.Count) {
        $zoneMappings | Export-Csv $zoneMappingsPath -NoTypeInformation -Encoding UTF8
    } else {
        'Region,Name,SubId,logical1,logical2,logical3,Pattern' |
            Set-Content $zoneMappingsPath -Encoding UTF8
    }

    if ($collectionErrors.Count) {
        $collectionErrors |
            Export-Csv (Join-Path $OutDir 'collection-errors.csv') -NoTypeInformation -Encoding UTF8
    }

    # Step 7: The summary describes collection coverage only. It intentionally does not calculate
    # quota differences so the recipient can apply their own migration and headroom assumptions.
    $summary = [ordered]@{
        GeneratedAt            = Get-Date -Format 's'
        TenantId               = $tenantId
        SubscriptionCount      = $subscriptions.Count
        PrimaryRegion          = $PrimaryRegion
        ExistingDrRegion       = $ExistingDrRegion
        TargetDrRegion         = $TargetDrRegion
        QuotaDataRows          = $quotaRows.Count
        PrimaryResourceRows    = $usedSkuRows.Count
        DiscoveredSkuCount     = $skus.Count
        SkuAvailabilityRows    = $skuAvailability.Count
        ZoneMappingRows        = $zoneMappings.Count
        CollectionErrorCount   = $collectionErrors.Count
        Notes                  = @(
            'Used and Limit are collected so both total-entitlement and available-headroom comparisons can be calculated.',
            'Quota is regional; SKU and availability-zone readiness are separate placement constraints.',
            'Informational rows and documented ceilings must not be treated as adjustable quota.',
            'Quota does not guarantee physical capacity.'
        )
    }
    $summary |
        ConvertTo-Json -Depth 5 |
        Set-Content (Join-Path $OutDir 'collection-summary.json') -Encoding UTF8

} finally {
    # Always restore the subscription that was active before collection, even after a partial failure.
    az account set --subscription $originalAccount.id 2>$null
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "Could not restore the original Azure CLI subscription $($originalAccount.id)."
    }

    # Remove only this script's known intermediate directory. Customer-facing outputs remain.
    if (Test-Path $workDir) { Remove-Item $workDir -Recurse -Force }
}

if (-not $SkipArchive) {
    $archivePath = "$OutDir.zip"
    if (Test-Path $archivePath) { Remove-Item $archivePath -Force }
    Compress-Archive -Path (Join-Path $OutDir '*') -DestinationPath $archivePath -Force
    Write-Host "`nArchive -> $archivePath" -ForegroundColor Green
}

Write-Host "`n=== Raw regional quota collection complete ===" -ForegroundColor Green
Write-Host "  Quota and usage : $(Join-Path $OutDir 'regional-quota-data.csv')"
Write-Host "  Primary SKUs    : $(Join-Path $OutDir 'primary-region-used-skus.csv')"
Write-Host "  SKU availability: $(Join-Path $OutDir 'sku-availability-by-region.csv')"
Write-Host "  Zone mappings   : $(Join-Path $OutDir 'availability-zone-mappings.csv')"
Write-Host "  Summary         : $(Join-Path $OutDir 'collection-summary.json')"
if ($collectionErrors.Count) {
    Write-Host "  Errors          : $(Join-Path $OutDir 'collection-errors.csv')" -ForegroundColor Yellow
}
Write-Host "`nThe output contains tenant-confidential data. Do not commit or share it outside the intended review."
