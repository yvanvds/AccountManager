<#
.SYNOPSIS
  Idempotently provision the Cosmos DB database/container set AND the Blob
  Storage account the centralized state layer (epic #112) requires.

.DESCRIPTION
  Stands up — reproducibly and safely to re-run — the full container set
  documented in docs/port-plan.md on the shared Cosmos account, plus the Blob
  Storage account and container the cold-snapshot overflow store (#107) writes
  to. Data-plane RBAC (Cosmos DB Built-in Data Contributor / Storage Blob Data
  Contributor) cannot create databases, containers, or accounts, so
  provisioning is a control-plane job that runs through the Azure CLI
  (az cosmosdb sql ... / az storage ...) under an identity with a management
  role. This replaces the prose "created out of band with az": the script IS
  the source of truth for what must exist.

  The Blob side (#161) closes the same drift as the Cosmos side: the storage
  account, the `snapshots` overflow container, and the operator's data-plane
  role were stood up by hand and never scripted, so a fresh environment could
  not reproduce them — the missing storage scope/account is exactly what made
  cold-snapshot Blob writes fail (AADSTS650057). It is folded in here so one
  script provisions the whole state backend.

  Every step is guarded by an `exists` check, so the script is idempotent: on
  an already-provisioned account it creates nothing and reports each resource
  as present; on a fresh (or partially provisioned) account it creates only
  what is missing. That closes the reproducibility gap in #160 — the drift
  where the six epic-#112 containers were never stood up on the shared account
  and surfaced only as a 403/404 at reconcile time.

  The nine containers, matching the table in docs/port-plan.md:

    Partition key /pk                 Partition key /id
    -----------------                 -----------------
    identity  (+ /naturalKey          settings
               unique-key policy)     snapshots
    passwordQueue                     syncState (TTL enabled, --ttl -1,
    linkedAccounts                               for the lease sweep)
    linkedGroups
    rollups
    decisions

  The identity container's /naturalKey unique-key policy is the convergence
  mechanism CosmosPersonIdResolver relies on (a second create for the same key
  is rejected 409). syncState has default-TTL enabled (--ttl -1: items don't
  expire by default, but a per-item `ttl` IS honored) so the sync/drift lease
  document is physically swept when its holder crashes (#108).

.PARAMETER AccountName
  The Cosmos DB account name. Default: accountmanager-cosmos-arcadia.

.PARAMETER ResourceGroup
  The resource group the account lives in. Default: accountmanager-rg.

.PARAMETER Database
  The SQL-API database name. Default: accountmanager.

.PARAMETER StorageAccount
  The Blob Storage account for cold-snapshot overflow payloads. Default:
  accountmanagerarcadia.

.PARAMETER StorageContainer
  The blob container holding the overflow snapshot payloads. Default: snapshots
  (the BLOB_SNAPSHOTS_CONTAINER default).

.PARAMETER Location
  The Azure region for the storage account. Default: belgiumcentral (matching
  the Cosmos account).

.PARAMETER OperatorObjectId
  Optional. The AAD object id of an operator principal to grant the *Storage
  Blob Data Contributor* data-plane role on the storage account. When omitted,
  the role assignment is skipped and the required role is reported as a
  prerequisite (mirroring how the Cosmos data role is assumed, not assigned).

.PARAMETER DryRun
  Print the provisioning plan (every az command that WOULD run) without
  touching Azure — no `exists` checks, no creates. Useful to review the exact
  container set / partition keys / TTL / unique-key policy before running for
  real, and to verify the script offline.

.EXAMPLE
  ./tool/provision-cosmos.ps1
  ./tool/provision-cosmos.ps1 -DryRun
  ./tool/provision-cosmos.ps1 -AccountName my-cosmos -ResourceGroup my-rg -Database mydb

.NOTES
  Requires the Azure CLI, authenticated (`az login`) as an identity holding a
  management role (e.g. DocumentDB Account Contributor) on the account — NOT
  the data-plane-only Cosmos DB Built-in Data Contributor role, which cannot
  create containers.
#>
[CmdletBinding()]
param(
  [string]$AccountName = 'accountmanager-cosmos-arcadia',
  [string]$ResourceGroup = 'accountmanager-rg',
  [string]$Database = 'accountmanager',
  [string]$StorageAccount = 'accountmanagerarcadia',
  [string]$StorageContainer = 'snapshots',
  [string]$Location = 'belgiumcentral',
  [string]$OperatorObjectId = '',
  [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

# The unique-key policy applied to the `identity` container: /naturalKey is
# globally unique because every identity document lives in one logical
# partition (see cosmos_config.dart / identityPartitionKeyValue).
$identityUniqueKeyPolicy = '{"uniqueKeys":[{"paths":["/naturalKey"]}]}'

# The nine containers docs/port-plan.md documents. `ttl` and `uniqueKeyPolicy`
# are optional per-container extras; when absent the container is created with
# just its partition key.
$containers = @(
  @{ Name = 'identity';       PartitionKey = '/pk'; UniqueKeyPolicy = $identityUniqueKeyPolicy }
  @{ Name = 'passwordQueue';  PartitionKey = '/pk' }
  @{ Name = 'linkedAccounts'; PartitionKey = '/pk' }
  @{ Name = 'linkedGroups';   PartitionKey = '/pk' }
  @{ Name = 'rollups';        PartitionKey = '/pk' }
  @{ Name = 'decisions';      PartitionKey = '/pk' }
  @{ Name = 'settings';       PartitionKey = '/id' }
  @{ Name = 'snapshots';      PartitionKey = '/id' }
  @{ Name = 'syncState';      PartitionKey = '/id'; Ttl = -1 }
)

function Invoke-Az {
  # Runs an az command, or — in -DryRun — just prints it and returns without
  # invoking az. Args are passed as an array so no shell re-quoting happens.
  param([string[]]$AzArgs)
  Write-Host "  az $($AzArgs -join ' ')"
  if ($DryRun) { return }
  $output = & az @AzArgs
  if ($LASTEXITCODE -ne 0) {
    throw "az $($AzArgs -join ' ') failed (exit $LASTEXITCODE): $output"
  }
  return $output
}

function Test-AzResource {
  # `az ... exists` prints `true`/`false`. In -DryRun we always report the
  # resource as missing so the plan shows the create it would perform.
  param([string[]]$AzArgs)
  if ($DryRun) {
    Write-Host "  az $($AzArgs -join ' ')  (dry-run: assume missing)"
    return $false
  }
  $result = & az @AzArgs
  if ($LASTEXITCODE -ne 0) {
    throw "az $($AzArgs -join ' ') failed (exit $LASTEXITCODE): $result"
  }
  return "$result".Trim() -eq 'true'
}

function Get-AzOutput {
  # Runs an az read that returns an arbitrary scalar (a state string, a resource
  # id, a count), trimmed. In -DryRun it makes no call and returns '' so the
  # caller takes its "missing/unset" branch and the create is shown in the plan.
  param([string[]]$AzArgs)
  if ($DryRun) {
    Write-Host "  az $($AzArgs -join ' ')  (dry-run: assume missing/unset)"
    return ''
  }
  $result = & az @AzArgs
  if ($LASTEXITCODE -ne 0) {
    throw "az $($AzArgs -join ' ') failed (exit $LASTEXITCODE): $result"
  }
  return "$result".Trim()
}

Write-Host "Provisioning Cosmos DB '$Database' on account '$AccountName' (rg '$ResourceGroup')"
if ($DryRun) { Write-Host "  [DRY RUN] no changes will be made" }
Write-Host ""

# 1. Database — create if missing so a fresh account provisions cleanly too.
Write-Host "Database '$Database':"
$dbExists = Test-AzResource @(
  'cosmosdb', 'sql', 'database', 'exists',
  '--account-name', $AccountName,
  '--resource-group', $ResourceGroup,
  '--name', $Database
)
if ($dbExists) {
  Write-Host "  present — skipping"
} else {
  Write-Host "  missing — creating"
  Invoke-Az @(
    'cosmosdb', 'sql', 'database', 'create',
    '--account-name', $AccountName,
    '--resource-group', $ResourceGroup,
    '--name', $Database
  ) | Out-Null
}
Write-Host ""

# 2. Containers — each guarded, created only when missing.
foreach ($c in $containers) {
  Write-Host "Container '$($c.Name)' (pk $($c.PartitionKey)):"
  $exists = Test-AzResource @(
    'cosmosdb', 'sql', 'container', 'exists',
    '--account-name', $AccountName,
    '--resource-group', $ResourceGroup,
    '--database-name', $Database,
    '--name', $c.Name
  )
  if ($exists) {
    Write-Host "  present — skipping"
    Write-Host ""
    continue
  }

  Write-Host "  missing — creating"
  $createArgs = @(
    'cosmosdb', 'sql', 'container', 'create',
    '--account-name', $AccountName,
    '--resource-group', $ResourceGroup,
    '--database-name', $Database,
    '--name', $c.Name,
    '--partition-key-path', $c.PartitionKey
  )
  if ($c.ContainsKey('Ttl')) {
    $createArgs += @('--ttl', "$($c.Ttl)")
  }
  if ($c.ContainsKey('UniqueKeyPolicy')) {
    $createArgs += @('--unique-key-policy', $c.UniqueKeyPolicy)
  }
  Invoke-Az $createArgs | Out-Null
  Write-Host ""
}

# 3. Blob Storage account + overflow container (#161 / cold-snapshot store #107).
#    The snapshot store writes payloads too large for a Cosmos document (>2 MB —
#    a whole-school WISA/Azure snapshot overflows) to Blob Storage. The account,
#    the `snapshots` container, and the operator's data-plane role were stood up
#    by hand and never scripted; the missing Storage scope/account is what made
#    those Blob writes fail with AADSTS650057. Folded in here, guarded the same
#    idempotent way as the Cosmos side, so a fresh environment reproduces it.

# 3a. Resource provider — Storage ARM calls fail (SubscriptionNotFound) until
#     Microsoft.Storage is registered on the subscription.
Write-Host "Resource provider 'Microsoft.Storage':"
$rpState = Get-AzOutput @(
  'provider', 'show',
  '--namespace', 'Microsoft.Storage',
  '--query', 'registrationState',
  '-o', 'tsv'
)
if ($rpState -eq 'Registered') {
  Write-Host "  registered — skipping"
} else {
  Write-Host "  '$rpState' — registering"
  Invoke-Az @('provider', 'register', '--namespace', 'Microsoft.Storage', '--wait') |
    Out-Null
}
Write-Host ""

# 3b. Storage account — AAD-only (shared-key access disabled, mirroring the
#     Cosmos account's disableLocalAuth), StorageV2, no public blob access.
Write-Host "Storage account '$StorageAccount':"
$saCount = Get-AzOutput @(
  'storage', 'account', 'list',
  '--resource-group', $ResourceGroup,
  '--query', "length([?name=='$StorageAccount'])",
  '-o', 'tsv'
)
if ($saCount -eq '1') {
  Write-Host "  present — skipping"
} else {
  Write-Host "  missing — creating"
  Invoke-Az @(
    'storage', 'account', 'create',
    '--name', $StorageAccount,
    '--resource-group', $ResourceGroup,
    '--location', $Location,
    '--sku', 'Standard_LRS',
    '--kind', 'StorageV2',
    '--min-tls-version', 'TLS1_2',
    '--allow-blob-public-access', 'false',
    '--allow-shared-key-access', 'false'
  ) | Out-Null
}
Write-Host ""

# 3c. Overflow container — with shared-key access disabled, every container op
#     must go through AAD (`--auth-mode login`).
Write-Host "Blob container '$StorageContainer':"
$containerExists = Get-AzOutput @(
  'storage', 'container', 'exists',
  '--account-name', $StorageAccount,
  '--name', $StorageContainer,
  '--auth-mode', 'login',
  '--query', 'exists',
  '-o', 'tsv'
)
if ($containerExists -eq 'true') {
  Write-Host "  present — skipping"
} else {
  Write-Host "  missing — creating"
  Invoke-Az @(
    'storage', 'container', 'create',
    '--account-name', $StorageAccount,
    '--name', $StorageContainer,
    '--auth-mode', 'login'
  ) | Out-Null
}
Write-Host ""

# 3d. Data-plane role — the app reaches Blob as the signed-in operator, who needs
#     Storage Blob Data Contributor on the account. Assigned only when an operator
#     object id is supplied; otherwise reported as a prerequisite, exactly as the
#     Cosmos data role is assumed rather than assigned.
Write-Host "Role 'Storage Blob Data Contributor' on '$StorageAccount':"
if ($OperatorObjectId) {
  $scope = Get-AzOutput @(
    'storage', 'account', 'show',
    '--name', $StorageAccount,
    '--resource-group', $ResourceGroup,
    '--query', 'id',
    '-o', 'tsv'
  )
  $assignments = Get-AzOutput @(
    'role', 'assignment', 'list',
    '--assignee', $OperatorObjectId,
    '--role', 'Storage Blob Data Contributor',
    '--scope', $scope,
    '--query', 'length(@)',
    '-o', 'tsv'
  )
  if ($assignments -ne '' -and $assignments -ne '0') {
    Write-Host "  already granted to $OperatorObjectId — skipping"
  } else {
    Write-Host "  missing — granting to $OperatorObjectId"
    Invoke-Az @(
      'role', 'assignment', 'create',
      '--assignee', $OperatorObjectId,
      '--role', 'Storage Blob Data Contributor',
      '--scope', $scope
    ) | Out-Null
  }
} else {
  Write-Host "  no -OperatorObjectId given — skipping (each operator must hold"
  Write-Host "  Storage Blob Data Contributor on the account, same as the Cosmos"
  Write-Host "  Built-in Data Contributor data role)"
}
Write-Host ""

Write-Host "Done."
