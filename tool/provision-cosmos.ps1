<#
.SYNOPSIS
  Idempotently provision the Cosmos DB database and container set the
  centralized state layer (epic #112) requires.

.DESCRIPTION
  Stands up — reproducibly and safely to re-run — the full container set
  documented in docs/port-plan.md on the shared Cosmos account. Data-plane
  RBAC (Cosmos DB Built-in Data Contributor) cannot create databases or
  containers, so provisioning is a control-plane job that runs through the
  Azure CLI (az cosmosdb sql ...) under an identity with a management role on
  the account. This replaces the prose "created out of band with az": the
  script IS the source of truth for what must exist.

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

Write-Host "Done."
