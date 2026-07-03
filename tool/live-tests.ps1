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

  Azure SQL works the same way as Azure: the bearer token is minted fresh for
  the SQL resource (https://database.windows.net/) rather than stored, and the
  server/database names come from .azuresql.env. That check is read-only -- it
  verifies the operator can mint a SQL-scoped token, and does not write to the
  database.

.PARAMETER Only
  Restrict the run to one connector: wisa, smartschool, azure, or azuresql.
  Default: all.

.EXAMPLE
  ./tool/live-tests.ps1
  ./tool/live-tests.ps1 -Only azure
  ./tool/live-tests.ps1 -Only azuresql
#>
[CmdletBinding()]
param(
  [ValidateSet('all', 'wisa', 'smartschool', 'azure', 'azuresql')]
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

  if ($Only -in @('all', 'azuresql')) {
    Import-EnvFile (Join-Path $repoRoot '.azuresql.env')
    Write-Host "  minting fresh read-only Azure SQL token via az..."
    $sqlTok = az account get-access-token --resource https://database.windows.net/ --query accessToken -o tsv
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($sqlTok)) {
      throw "az account get-access-token failed. Run 'az login' first (with an account that is an AAD admin on the SQL server)."
    }
    $env:AZURE_SQL_ACCESS_TOKEN = $sqlTok
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
