<#
.SYNOPSIS
  Run the opt-in live integration tests against the real WISA / Smartschool /
  Azure hosts, provisioning credentials from the local .*.env files.

.DESCRIPTION
  Loads .wisa.env, .smartschool.env and .azure.env (all gitignored) into the
  process environment, then runs each connector's integration test.

  Azure is special: a stored bearer token is useless because it expires in
  ~1 hour. So instead of reading AZURE_ACCESS_TOKEN from a file, this script
  mints a FRESH read-only Graph token via the Azure CLI
  (az account get-access-token) -- the local mirror of how CI mints one via
  OIDC workload-identity federation. The other AZURE_* values (client/tenant/
  domain/prefix) still come from .azure.env.

  Each connector's test self-skips when its trigger var is absent, so a
  missing .env file just skips that connector rather than failing.

  Cosmos works the same way as Azure: the bearer token is minted fresh for the
  Cosmos resource (https://cosmos.azure.com) rather than stored, and the
  endpoint/database names come from .cosmos.env. That check is write-capable
  (it round-trips the settings/queue documents and mints a disposable identity
  key), so it is manual/opt-in only -- not run in CI -- per the live-testing
  policy, and each test restores or deletes what it wrote.

.PARAMETER Only
  Restrict the run to one connector: wisa, smartschool, azure, or cosmos.
  Default: all.

.EXAMPLE
  ./tool/live-tests.ps1
  ./tool/live-tests.ps1 -Only azure
  ./tool/live-tests.ps1 -Only cosmos
#>
[CmdletBinding()]
param(
  [ValidateSet('all', 'wisa', 'smartschool', 'azure', 'cosmos')]
  [string]$Only = 'all'
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot

function Import-EnvFile {
  param([string]$Path)
  if (-not (Test-Path $Path)) {
    Write-Host "  (skip) $(Split-Path -Leaf $Path) not found; its tests will self-skip"
    return
  }
  Get-Content $Path | ForEach-Object {
    if ($_ -match '^([^#=]+)=(.*)$') {
      Set-Item "env:$($matches[1].Trim())" $matches[2]
    }
  }
  Write-Host "  loaded $(Split-Path -Leaf $Path)"
}

Push-Location $repoRoot
try {
  $dirs = @()

  if ($Only -in @('all', 'wisa')) {
    Import-EnvFile (Join-Path $repoRoot '.wisa.env')
    $dirs += 'packages/wisa_api/test/integration/'
  }

  if ($Only -in @('all', 'smartschool')) {
    Import-EnvFile (Join-Path $repoRoot '.smartschool.env')
    $dirs += 'packages/smartschool_api/test/integration/'
  }

  if ($Only -in @('all', 'azure')) {
    Import-EnvFile (Join-Path $repoRoot '.azure.env')
    Write-Host "  minting fresh read-only Azure Graph token via az..."
    $tok = az account get-access-token --resource https://graph.microsoft.com --query accessToken -o tsv
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($tok)) {
      throw "az account get-access-token failed. Run 'az login' first (with an account that has directory read access)."
    }
    $env:AZURE_ACCESS_TOKEN = $tok
    $dirs += 'packages/azure_api/test/integration/'
  }

  if ($Only -in @('all', 'cosmos')) {
    Import-EnvFile (Join-Path $repoRoot '.cosmos.env')
    Write-Host "  minting fresh Cosmos data-plane token via az..."
    $cosmosTok = az account get-access-token --resource https://cosmos.azure.com --query accessToken -o tsv
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($cosmosTok)) {
      throw "az account get-access-token failed. Run 'az login' first (with an account that holds the Cosmos DB Built-in Data Contributor role)."
    }
    $env:COSMOS_ACCESS_TOKEN = $cosmosTok
    $dirs += 'packages/account_state/test/integration/'
  }

  $dirList = $dirs -join ' '
  Write-Host ""
  Write-Host "dart test $dirList"
  dart test @dirs
}
finally {
  Pop-Location
}
