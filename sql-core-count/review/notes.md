# Code Review Notes — FinOps v1 Scripts

Reviewed: 2026-03-10
Source: VectorBrad/FinOps (main branch)
Scripts: Azure Functions, HTTP-triggered, PowerShell

---

## What These Scripts Do

All four scripts follow an identical pattern:
1. Run as **Azure Function HTTP triggers**
2. Read three env vars: `STORAGE_ACCOUNT`, `STORAGE_ACCOUNT_KEY`, `CONTAINER_NAME`
3. Query Azure Resource Graph (`Search-AzGraph`) for a specific resource type
4. Build a CSV byte-by-byte
5. Upload the CSV to Azure Blob Storage

### Per-Script Resource Targets

| Script | Resource Type | Key Fields |
|---|---|---|
| GetElasticPoolCoreCount | `microsoft.sql/servers/elasticpools` | min/maxCapacity, licenseType, maxSizeBytes |
| GetSQLDBCoreCount | `microsoft.sql/servers/databases` | SKU name/capacity/tier, elasticPoolId, licenseType, HA replicas |
| GetSQLMICoreCount | `microsoft.sql/managedinstances` | vCores, licenseType, storageSizeInGB |
| GetVMCoreCount | `microsoft.compute/virtualmachines` joined to `Microsoft.SqlVirtualMachine/SqlVirtualMachines` | vmSize, edition, vCores |

**VMCoreCount is the most selective** — it filters to RGs containing `-dbs`, excludes deallocated/stopped VMs, and inner-joins to SQL VM resources (so only VMs running SQL Server are returned).

---

## Bugs

### 1. `$outputFilename` vs `$outputFileName` casing bug — GetElasticPoolCoreCount
- Line 13: `$outputFilename = "ElasticPoolCoreCount.csv"` (lowercase 'n')
- Line 19: `$outputFileName = $filenameParam + ".csv"` (uppercase 'N')
- Line 102: references `$outputFileName`
- **Result:** If no `FileName` param is passed, `$outputFileName` is never set from the default. The upload on line 102 uses an empty or null filename. The other three scripts don't have this bug.

### 2. Newline bytes are wrong in all four scripts
- `'0x0d' + '0x0a'` appends the *strings* `"0x0d"` and `"0x0a"`, not actual CRLF bytes.
- The CSV will have the literal text `0x0d0x0a` appended to every line instead of a carriage return + line feed.
- This means the output file is not valid CSV — it's one long line with `0x0d0x0a` between records.

### 3. `$subscriptionName` not in Resource Graph results — GetElasticPoolCoreCount
- The KQL query projects `tostring(properties['subscriptionName'])` but `subscriptionName` is not a standard property on elastic pool resources. This will return null/empty for every row.
- Same issue may apply to other scripts depending on tenant configuration.

### 4. `$tenantId` is a PSObject, not a string
- `Get-AzTenant | Select-Object TenantId` returns a PSObject with a TenantId property, not the raw GUID.
- `Set-AzContext -Tenant $tenantId` may fail or silently pass the wrong value depending on how PowerShell coerces it. Should be `(Get-AzTenant).TenantId`.

### 5. Hard 1000-row limit with no pagination
- `-First 1000` is used but Resource Graph has a max page size of 1000. If results exceed 1000, the rest are silently dropped.
- No `$skipToken` / pagination loop is implemented.

### 6. VMCoreCount column order mismatch
- CSV header (line 80): `Name,ResourceGroup,SubscriptionId,Location,HardwareProfileVMSize,vCores,Edition,...`
- Data row (line 93): `$name,$resourceGroup,$subscriptionId,$location,$hardwareProfileVMSize,$vCores,$edition,...`
- The KQL query projects `vmSize, edition, vCores` but the data row writes `vCores` before `edition`.
- Header says vCores col 6, edition col 7 — row writes vCores col 6, edition col 7. Actually consistent, but KQL join output order is `vmSize, edition, vCores` which differs — worth verifying actual column mapping.

### 7. Storage account key in env var (minor security note)
- Using a storage account key gives full account access. Managed Identity + role assignment would be preferable in production.

---

## Code Quality Issues

| # | Issue | Affects |
|---|---|---|
| Q1 | Identical boilerplate repeated across 4 files (env check, tenant setup, blob upload) | All |
| Q2 | CSV built as byte arrays manually instead of using `Export-Csv` or `ConvertTo-Csv` | All |
| Q3 | `Write-Host "Number of bytes in result:"` then `Write-Host $bytesResult.Length` — two lines, could be one | All |
| Q4 | `$moduleVersion` logged but `Get-Command` returns an array — output will be noisy/unhelpful | All |
| Q5 | `$currSubs` logged but never used — dead code | All |
| Q6 | `$body` set to success message before upload, then overwritten with the file-written message — success message is lost in VMCoreCount (line 110 replaces instead of appends) | GetVMCoreCount |
| Q7 | No error handling — if the graph query or blob upload throws, the function crashes with no useful response | All |

---

## Summary: What Works

- Core concept is sound: HTTP trigger → Resource Graph query → CSV → Blob Storage
- Auth pattern (managed identity implied via `Get-AzTenant`) is reasonable
- Filtering approach in VMCoreCount (join to SqlVirtualMachines) is the right way to find SQL-licensed VMs
- Adding `EntryDate` to every row is good for historical tracking

## Summary: What Needs Fixing in v2

**Must fix (functional bugs):**
1. CRLF byte encoding
2. `$outputFilename` casing bug in ElasticPool
3. `$tenantId` PSObject coercion

**Should fix (reliability):**
4. Pagination beyond 1000 rows
5. Error handling (try/catch around query and upload)

**Worth improving (quality):**
6. Extract shared boilerplate into a shared module or helper function
7. Replace manual byte-array CSV with `ConvertTo-Csv`
8. Verify `subscriptionName` field availability or remove it
9. Switch from storage account key to Managed Identity

---
