using namespace System.Net

# =============================================================================
# GetVMCoreCount
# Queries Azure Resource Graph for all VMs running SQL Server across the tenant
# (identified by inner join to SqlVirtualMachines resource type) and writes
# the results as a CSV to Azure Blob Storage.
# Excludes deallocated and stopped VMs.
#
# TRIGGER: HTTP (default) — call this function via HTTP request.
# To run on a schedule instead, replace function.json with:
#   {
#     "bindings": [{
#       "type": "timerTrigger",
#       "direction": "in",
#       "name": "Timer",
#       "schedule": "0 0 6 * * *"
#     }]
#   }
# Then change the param block below to: param($Timer, $TriggerMetadata)
#
# OPTIONAL QUERY PARAMETERS:
#   FileName       — override the output filename (without .csv extension)
#   ResourceGroup  — filter to RGs containing this string
#   SubscriptionId — filter to a single subscription
#
# ENVIRONMENT VARIABLES:
#   STORAGE_ACCOUNT     (required) — storage account name
#   CONTAINER_NAME      (required) — blob container name
#   STORAGE_ACCOUNT_KEY (optional) — if omitted, Managed Identity is used
# =============================================================================

param($Request, $TriggerMetadata)

Write-Host "GetVMCoreCount function started."

# --- Required config ---
$storageAccountName = $env:STORAGE_ACCOUNT
$containerName      = $env:CONTAINER_NAME
$storageAccountKey  = $env:STORAGE_ACCOUNT_KEY  # Leave unset to use Managed Identity

$configErrors = @()
if (-not $storageAccountName) { $configErrors += "STORAGE_ACCOUNT environment variable is not set." }
if (-not $containerName)      { $configErrors += "CONTAINER_NAME environment variable is not set." }
if ($configErrors.Count -gt 0) {
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::BadRequest
        Body       = $configErrors -join " "
    })
    return
}

# --- Optional parameters ---
$outputFileName = "VMCoreCount.csv"
$fileNameParam  = if ($Request.Query.FileName)   { $Request.Query.FileName }
                  elseif ($Request.Body.FileName) { $Request.Body.FileName }
if ($fileNameParam) { $outputFileName = $fileNameParam + ".csv" }

$filterResourceGroup  = if ($Request.Query.ResourceGroup)    { $Request.Query.ResourceGroup }
                        elseif ($Request.Body.ResourceGroup)  { $Request.Body.ResourceGroup }
$filterSubscriptionId = if ($Request.Query.SubscriptionId)   { $Request.Query.SubscriptionId }
                        elseif ($Request.Body.SubscriptionId) { $Request.Body.SubscriptionId }

# --- Azure context (tenant-wide) ---
$tenantId = (Get-AzTenant).TenantId
Write-Host "Tenant ID: $tenantId"
Set-AzContext -Tenant $tenantId

# --- Subscription ID → Name lookup ---
$subscriptionMap = @{}
Get-AzSubscription | ForEach-Object { $subscriptionMap[$_.Id] = $_.Name }
$PSDefaultParameterValues = @{ "Search-AzGraph:Subscription" = $subscriptionMap.Keys }

# --- Build KQL query ---
# Inner join to SqlVirtualMachines ensures only SQL-licensed VMs are returned.
# Deallocated and stopped VMs are excluded — they are not consuming SQL licenses.
$vmQuery  = 'resources'
$vmQuery += ' | where type =~ "microsoft.compute/virtualmachines"'
$vmQuery += ' | where properties.extended.instanceView.powerState.code != "PowerState/deallocated"'
$vmQuery += ' | where properties.extended.instanceView.powerState.code != "PowerState/stopped"'
$vmQuery += ' | project name, resourceGroup, subscriptionId, location,'
$vmQuery += ' vmSize = properties["hardwareProfile"].vmSize,'
$vmQuery += ' vCores = tostring(properties["vCores"])'
$vmQuery += ' | join kind=inner ('
$vmQuery += '     resources'
$vmQuery += '     | where type =~ "Microsoft.SqlVirtualMachine/SqlVirtualMachines"'
$vmQuery += '     | project name, edition = properties.sqlImageSku'
$vmQuery += ' ) on name'
$vmQuery += ' | project name, resourceGroup, subscriptionId, location, vmSize, edition, vCores'
if ($filterResourceGroup)  { $vmQuery += " | where resourceGroup contains '$filterResourceGroup'" }
if ($filterSubscriptionId) { $vmQuery += " | where subscriptionId == '$filterSubscriptionId'" }
$vmQuery += ' | order by resourceGroup asc'

Write-Host "Running query to retrieve VM-hosted SQL core count..."

# --- Paginated query ---
try {
    $allResults  = @()
    $queryParams = @{ First = 1000; Query = $vmQuery }
    do {
        $page        = Search-AzGraph @queryParams
        $allResults += $page
        $queryParams['SkipToken'] = $page.SkipToken
    } while ($page.SkipToken)
    Write-Host "Total records retrieved: $($allResults.Count)"
} catch {
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::InternalServerError
        Body       = "Query failed: $_"
    })
    return
}

if ($allResults.Count -eq 0) {
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::OK
        Body       = "Query returned no results. Check filters and permissions."
    })
    return
}

# --- Build CSV rows ---
$entryDate = Get-Date -Format "yyyy-MM-dd"
$rows = foreach ($r in $allResults) {
    [PSCustomObject]@{
        Name             = $r.name
        ResourceGroup    = $r.resourceGroup
        SubscriptionId   = $r.subscriptionId
        SubscriptionName = $subscriptionMap[$r.subscriptionId]
        Location         = $r.location
        VMSize           = $r.vmSize
        Edition          = $r.edition
        vCores           = $r.vCores
        EntryDate        = $entryDate
    }
}

$csvContent = ($rows | ConvertTo-Csv -NoTypeInformation) -join "`r`n"
$csvBytes   = [System.Text.Encoding]::UTF8.GetBytes($csvContent)

# --- Upload to blob (key auth if available, else Managed Identity) ---
try {
    if ($storageAccountKey) {
        Write-Host "Authenticating to storage using account key."
        $storageContext = New-AzStorageContext -StorageAccountName $storageAccountName -StorageAccountKey $storageAccountKey
    } else {
        Write-Host "Authenticating to storage using Managed Identity."
        $storageContext = New-AzStorageContext -StorageAccountName $storageAccountName -UseConnectedAccount
    }

    $container = Get-AzStorageContainer -Name $containerName -Context $storageContext
    $container.CloudBlobContainer.GetBlockBlobReference($outputFileName).UploadFromByteArray($csvBytes, 0, $csvBytes.Length)

    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::OK
        Body       = "Success — $($rows.Count) records written to $outputFileName"
    })
} catch {
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::InternalServerError
        Body       = "Upload failed: $_"
    })
}
