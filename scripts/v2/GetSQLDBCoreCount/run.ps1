using namespace System.Net

# =============================================================================
# GetSQLDBCoreCount
# Queries Azure Resource Graph for all SQL Databases across the tenant
# and writes the results as a CSV to Azure Blob Storage.
# Excludes the system 'master' database.
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

Write-Host "GetSQLDBCoreCount function started."

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
$outputFileName = "SQLDBCoreCount.csv"
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
$sqldbQuery  = 'resources'
$sqldbQuery += ' | where type =~ "microsoft.sql/servers/databases"'
$sqldbQuery += ' | where name != "master"'
$sqldbQuery += ' | project name, resourceGroup, subscriptionId, location,'
$sqldbQuery += ' tostring(properties["elasticPoolId"]),'
$sqldbQuery += ' properties["currentSku"].name, properties["currentSku"].capacity, properties["currentSku"].tier,'
$sqldbQuery += ' properties["maxSizeBytes"]/1024/1024/1024,'
$sqldbQuery += ' tostring(properties["highAvailabilityReplicaCount"]),'
$sqldbQuery += ' tostring(properties["licenseType"])'
if ($filterResourceGroup)  { $sqldbQuery += " | where resourceGroup contains '$filterResourceGroup'" }
if ($filterSubscriptionId) { $sqldbQuery += " | where subscriptionId == '$filterSubscriptionId'" }

Write-Host "Running query to retrieve SQL Database core count..."

# --- Paginated query ---
try {
    $allResults  = @()
    $queryParams = @{ First = 1000; Query = $sqldbQuery }
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
        Name                     = $r.name
        ResourceGroup            = $r.resourceGroup
        SubscriptionId           = $r.subscriptionId
        SubscriptionName         = $subscriptionMap[$r.subscriptionId]
        Location                 = $r.location
        ElasticPoolId            = $r.properties_elasticPoolId
        CurrentSKUName           = $r.properties_currentSku_name
        CurrentSKUCapacity       = $r.properties_currentSku_capacity
        CurrentSKUTier           = $r.properties_currentSku_tier
        MaxSizeGB                = $r.Column1
        HighAvailabilityReplicas = $r.properties_highAvailabilityReplicaCount
        LicenseType              = $r.properties_licenseType
        EntryDate                = $entryDate
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
