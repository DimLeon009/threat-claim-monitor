[CmdletBinding()]
param(
  [ValidateRange(1024, 65535)]
  [int]$N8nPort = 25678
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$projectName = "tcm-win-install-$PID-$([DateTime]::UtcNow.ToString('yyyyMMddHHmmss'))".ToLowerInvariant()
$previousN8nPort = [Environment]::GetEnvironmentVariable('N8N_PORT', 'Process')
$stackCreated = $false

function Invoke-IsolatedCompose {
  param([Parameter(Mandatory = $true)][string[]]$Arguments)

  & docker compose --project-name $projectName @Arguments
  if ($LASTEXITCODE -ne 0) {
    throw "Isolated Docker Compose command failed: $($Arguments -join ' ')"
  }
}

function Get-PostgresScalar {
  param(
    [Parameter(Mandatory = $true)][string]$Database,
    [Parameter(Mandatory = $true)][string]$Query
  )

  $result = Invoke-IsolatedCompose -Arguments @(
    'exec', '-T', 'postgres', 'psql',
    '--username', 'tcm_admin', '--dbname', $Database,
    '--tuples-only', '--no-align', '--command', $Query
  )
  return ($result | Out-String).Trim()
}

Push-Location $repositoryRoot
try {
  if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    throw 'Docker was not found. Start Docker Desktop and rerun the Windows installation validation.'
  }
  if (-not (Test-Path -LiteralPath '.env')) {
    throw 'A configured local .env file is required for the isolated installation test.'
  }
  if (Select-String -LiteralPath '.env' -Pattern 'change-me-' -Quiet) {
    throw 'Replace every change-me placeholder in .env before running the isolated installation test.'
  }

  $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, $N8nPort)
  try {
    $listener.Start()
  }
  catch {
    throw "The isolated n8n port $N8nPort is already in use. Choose another -N8nPort value."
  }
  finally {
    $listener.Stop()
  }

  $env:N8N_PORT = [string]$N8nPort
  Invoke-IsolatedCompose -Arguments @('config', '--quiet')
  $stackCreated = $true
  Invoke-IsolatedCompose -Arguments @('up', '-d', '--wait')

  $runningServices = @(Invoke-IsolatedCompose -Arguments @(
    'ps', '--status', 'running', '--services'
  ))
  foreach ($service in @('postgres', 'n8n')) {
    if ($runningServices -notcontains $service) {
      throw "The isolated $service service is not running."
    }
  }

  $expectedMigrationCount = @(
    Get-ChildItem -LiteralPath 'db/migrations' -File -Filter '*.sql'
  ).Count
  $actualMigrationCount = [int](
    Get-PostgresScalar -Database 'threat_claim_monitor' `
      -Query 'SELECT count(*) FROM schema_migrations;'
  )
  if ($actualMigrationCount -ne $expectedMigrationCount) {
    throw "Expected $expectedMigrationCount migrations but found $actualMigrationCount."
  }

  $databaseCount = [int](
    Get-PostgresScalar -Database 'postgres' `
      -Query "SELECT count(*) FROM pg_database WHERE datname IN ('n8n', 'threat_claim_monitor');"
  )
  if ($databaseCount -ne 2) {
    throw 'The clean installation did not create both required databases.'
  }

  $sourceCount = [int](
    Get-PostgresScalar -Database 'threat_claim_monitor' `
      -Query 'SELECT count(*) FROM sources;'
  )
  if ($sourceCount -lt 3) {
    throw 'The clean installation did not seed the expected source configuration.'
  }

  $n8nVersion = (
    Invoke-IsolatedCompose -Arguments @('exec', '-T', 'n8n', 'n8n', '--version') |
      Out-String
  ).Trim()
  if ($n8nVersion -ne '2.36.7') {
    throw "Expected n8n 2.36.7 but the isolated service reports $n8nVersion."
  }

  $n8nContainerId = (
    Invoke-IsolatedCompose -Arguments @('ps', '--quiet', 'n8n') | Out-String
  ).Trim()
  $postgresContainerId = (
    Invoke-IsolatedCompose -Arguments @('ps', '--quiet', 'postgres') | Out-String
  ).Trim()
  $n8nPorts = (& docker inspect --format '{{json .NetworkSettings.Ports}}' $n8nContainerId) |
    ConvertFrom-Json
  if ($LASTEXITCODE -ne 0) {
    throw 'Could not inspect the isolated n8n port binding.'
  }
  $n8nBinding = @($n8nPorts.'5678/tcp')
  if ($n8nBinding.Count -ne 1 -or
      $n8nBinding[0].HostIp -ne '127.0.0.1' -or
      [int]$n8nBinding[0].HostPort -ne $N8nPort) {
    throw 'n8n is not bound exclusively to the requested Windows loopback port.'
  }

  $postgresPorts = (& docker inspect --format '{{json .NetworkSettings.Ports}}' $postgresContainerId) |
    ConvertFrom-Json
  if ($LASTEXITCODE -ne 0) {
    throw 'Could not inspect the isolated PostgreSQL port binding.'
  }
  if ($null -ne $postgresPorts.'5432/tcp') {
    throw 'PostgreSQL is unexpectedly published to the Windows host.'
  }

  $healthReady = $false
  for ($attempt = 1; $attempt -le 15; $attempt++) {
    & curl.exe --fail --silent --max-time 5 `
      "http://localhost:$N8nPort/healthz" | Out-Null
    if ($LASTEXITCODE -eq 0) {
      $healthReady = $true
      break
    }
    Start-Sleep -Seconds 2
  }
  if (-not $healthReady) {
    throw 'The isolated n8n health endpoint did not return a successful response.'
  }

  $n8nSchemaReady = $false
  for ($attempt = 1; $attempt -le 15; $attempt++) {
    $requiredTablesReady = Get-PostgresScalar -Database 'n8n' -Query @"
SELECT to_regclass('public.workflow_entity') IS NOT NULL
   AND to_regclass('public.execution_entity') IS NOT NULL;
"@
    if ($requiredTablesReady -eq 't') {
      $n8nSchemaReady = $true
      break
    }
    Start-Sleep -Seconds 2
  }
  if (-not $n8nSchemaReady) {
    throw 'The isolated n8n database migrations did not finish within the bounded wait.'
  }

  $workflowCount = [int](
    Get-PostgresScalar -Database 'n8n' -Query 'SELECT count(*) FROM workflow_entity;'
  )
  $executionCount = [int](
    Get-PostgresScalar -Database 'n8n' -Query 'SELECT count(*) FROM execution_entity;'
  )
  if ($workflowCount -ne 0 -or $executionCount -ne 0) {
    throw 'The isolated n8n database is not a clean first-start state.'
  }

  Write-Host "Isolated project: $projectName"
  Write-Host "n8n version: $n8nVersion"
  Write-Host "Applied migrations: $actualMigrationCount"
  Write-Host "Seeded sources: $sourceCount"
  Write-Host "n8n binding: 127.0.0.1:$N8nPort"
  Write-Host 'PostgreSQL host binding: none'
  Write-Host 'Windows clean-install runtime validation passed.' -ForegroundColor Green
}
finally {
  if ($stackCreated) {
    & docker compose --project-name $projectName down --volumes --remove-orphans
    if ($LASTEXITCODE -ne 0) {
      Write-Warning "Could not completely remove isolated Compose project $projectName."
    }
  }
  if ($null -eq $previousN8nPort) {
    Remove-Item Env:N8N_PORT -ErrorAction SilentlyContinue
  } else {
    $env:N8N_PORT = $previousN8nPort
  }
  Pop-Location
}
