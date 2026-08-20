[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string]$DestinationDirectory,

  [string]$PostgresUser = 'tcm_admin',

  [string]$ComposeProjectName = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$composePrefix = @('compose')
if ($ComposeProjectName) {
  $composePrefix += @('-p', $ComposeProjectName)
}

function Invoke-Compose {
  param([Parameter(Mandatory = $true)][string[]]$Arguments)

  & docker @composePrefix @Arguments
  if ($LASTEXITCODE -ne 0) {
    throw "Docker Compose command failed: $($Arguments -join ' ')"
  }
}

function Get-DatabaseScalar {
  param(
    [Parameter(Mandatory = $true)][string]$Database,
    [Parameter(Mandatory = $true)][string]$Query
  )

  $result = Invoke-Compose -Arguments @(
    'exec', '-T', 'postgres',
    'psql', '--username', $PostgresUser, '--dbname', $Database,
    '--tuples-only', '--no-align', '--command', $Query
  )
  return ($result | Out-String).Trim()
}

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
  throw 'Docker was not found. Start Docker Desktop and try again.'
}

Push-Location $repositoryRoot
$operationStopwatch = [Diagnostics.Stopwatch]::StartNew()
$n8nWasRunning = $false
$backupSucceeded = $false
$containerTempCreated = $false
$n8nArchiveCreated = $false
$containerTempDirectory = "/tmp/tcm-backup-$([guid]::NewGuid().ToString('N'))"
$n8nArchiveName = 'n8n-data.tar.gz'

try {
  if (-not (Test-Path '.env')) {
    throw 'The local .env file is required. It is not copied into the backup.'
  }

  Invoke-Compose -Arguments @('config', '--quiet')
  $runningServices = @(Invoke-Compose -Arguments @('ps', '--status', 'running', '--services'))
  if ($runningServices -notcontains 'postgres') {
    throw 'PostgreSQL must be running before a backup can be created.'
  }
  $n8nWasRunning = $runningServices -contains 'n8n'

  $resolvedDestination = [IO.Path]::GetFullPath(
    (Join-Path (Get-Location) $DestinationDirectory)
  )
  $backupName = "tcm-backup-$([DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ'))"
  $backupDirectory = Join-Path $resolvedDestination $backupName
  if (Test-Path -LiteralPath $backupDirectory) {
    throw "Backup target already exists: $backupDirectory"
  }
  [IO.Directory]::CreateDirectory($backupDirectory) | Out-Null

  if ($n8nWasRunning) {
    Invoke-Compose -Arguments @('stop', 'n8n')
  }

  Invoke-Compose -Arguments @('exec', '-T', 'postgres', 'mkdir', '-m', '700', $containerTempDirectory)
  $containerTempCreated = $true
  Invoke-Compose -Arguments @(
    'exec', '-T', 'postgres',
    'pg_dump', '--username', $PostgresUser,
    '--dbname', 'threat_claim_monitor', '--format', 'custom',
    '--no-owner', '--no-privileges', '--file', "$containerTempDirectory/threat_claim_monitor.dump"
  )
  Invoke-Compose -Arguments @(
    'exec', '-T', 'postgres',
    'pg_dump', '--username', $PostgresUser,
    '--dbname', 'n8n', '--format', 'custom',
    '--no-owner', '--no-privileges', '--file', "$containerTempDirectory/n8n.dump"
  )
  Invoke-Compose -Arguments @(
    'cp', "postgres:$containerTempDirectory/threat_claim_monitor.dump",
    (Join-Path $backupDirectory 'threat_claim_monitor.dump')
  )
  Invoke-Compose -Arguments @(
    'cp', "postgres:$containerTempDirectory/n8n.dump",
    (Join-Path $backupDirectory 'n8n.dump')
  )

  Invoke-Compose -Arguments @('create', 'n8n')
  $archiveCommand = "tar -czf /home/node/.n8n/$n8nArchiveName --exclude=./config --exclude=./$n8nArchiveName -C /home/node/.n8n ."
  Invoke-Compose -Arguments @(
    'run', '--rm', '--no-deps', '--user', 'node', '--entrypoint', 'sh',
    'n8n', '-c', $archiveCommand
  )
  $n8nArchiveCreated = $true
  Invoke-Compose -Arguments @(
    'cp', "n8n:/home/node/.n8n/$n8nArchiveName",
    (Join-Path $backupDirectory $n8nArchiveName)
  )

  $migrationVersions = @(
    (Get-DatabaseScalar -Database 'threat_claim_monitor' -Query 'SELECT version FROM schema_migrations ORDER BY version;') -split "`r?`n" |
      Where-Object { $_ }
  )
  $applicationCounts = [ordered]@{}
  foreach ($table in @(
    'sources', 'organizations', 'collection_runs', 'observations', 'claims',
    'analyses', 'notification_outbox', 'notification_attempts'
  )) {
    $applicationCounts[$table] = [int64](
      Get-DatabaseScalar -Database 'threat_claim_monitor' -Query "SELECT count(*) FROM $table;"
    )
  }

  $files = [ordered]@{}
  foreach ($filename in @('threat_claim_monitor.dump', 'n8n.dump', $n8nArchiveName)) {
    $path = Join-Path $backupDirectory $filename
    $files[$filename] = [ordered]@{
      sha256 = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
      bytes = (Get-Item -LiteralPath $path).Length
    }
  }

  $manifest = [ordered]@{
    contract_version = 'tcm-backup-v1'
    created_at_utc = [DateTime]::UtcNow.ToString('o')
    backup_duration_seconds = [Math]::Round($operationStopwatch.Elapsed.TotalSeconds, 3)
    postgres_version = Get-DatabaseScalar -Database 'threat_claim_monitor' -Query 'SHOW server_version;'
    databases = @('threat_claim_monitor', 'n8n')
    schema_migrations = $migrationVersions
    application_row_counts = $applicationCounts
    n8n_volume = [ordered]@{
      included = $true
      config_excluded = $true
      original_encryption_key_required = $true
    }
    files = $files
  }
  $manifestJson = $manifest | ConvertTo-Json -Depth 8
  [IO.File]::WriteAllText(
    (Join-Path $backupDirectory 'manifest.json'),
    $manifestJson,
    [Text.UTF8Encoding]::new($false)
  )

  $backupSucceeded = $true
  Write-Host "Backup created: $backupDirectory" -ForegroundColor Green
  Write-Host "Backup duration: $([Math]::Round($operationStopwatch.Elapsed.TotalSeconds, 3)) seconds"
  Write-Host 'Store this directory securely and preserve N8N_ENCRYPTION_KEY separately.' -ForegroundColor Yellow
}
finally {
  if ($containerTempCreated) {
    try {
      Invoke-Compose -Arguments @(
        'exec', '-T', 'postgres', 'rm', '-f',
        "$containerTempDirectory/threat_claim_monitor.dump",
        "$containerTempDirectory/n8n.dump"
      )
      Invoke-Compose -Arguments @('exec', '-T', 'postgres', 'rmdir', $containerTempDirectory)
    }
    catch {
      Write-Warning 'Could not remove the bounded PostgreSQL backup temporary files.'
    }
  }
  if ($n8nArchiveCreated) {
    try {
      Invoke-Compose -Arguments @(
        'run', '--rm', '--no-deps', '--user', 'node', '--entrypoint', 'rm',
        'n8n', '-f', "/home/node/.n8n/$n8nArchiveName"
      )
    }
    catch {
      Write-Warning 'Could not remove the bounded n8n backup temporary archive.'
    }
  }

  if ($n8nWasRunning) {
    Invoke-Compose -Arguments @('start', 'n8n')
  }
  Pop-Location

  if (-not $backupSucceeded) {
    Write-Warning 'Backup did not complete. Do not use an incomplete backup directory.'
  }
}
