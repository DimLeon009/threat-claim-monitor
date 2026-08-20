[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string]$BackupDirectory,

  [Parameter(Mandatory = $true)]
  [switch]$ConfirmReplaceTargetDatabases,

  [Parameter(Mandatory = $true)]
  [switch]$ConfirmOriginalEncryptionKey,

  [string]$PostgresUser = 'tcm_admin',

  [string]$ComposeProjectName = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if (-not $ConfirmReplaceTargetDatabases) {
  throw 'Restore refused: explicitly confirm replacement of both target databases.'
}
if (-not $ConfirmOriginalEncryptionKey) {
  throw 'Restore refused: confirm that the original N8N_ENCRYPTION_KEY is configured.'
}
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
  throw 'Docker was not found. Start Docker Desktop and try again.'
}

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

$resolvedBackup = [IO.Path]::GetFullPath(
  (Join-Path (Get-Location) $BackupDirectory)
)
$manifestPath = Join-Path $resolvedBackup 'manifest.json'
if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
  throw "Backup manifest not found: $manifestPath"
}
$manifest = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json
if ($manifest.contract_version -ne 'tcm-backup-v1') {
  throw 'Unsupported backup contract version.'
}

foreach ($filename in @('threat_claim_monitor.dump', 'n8n.dump', 'n8n-data.tar.gz')) {
  $path = Join-Path $resolvedBackup $filename
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
    throw "Backup file is missing: $filename"
  }
  $expectedHash = $manifest.files.$filename.sha256
  $actualHash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
  if ($actualHash -ne $expectedHash) {
    throw "Backup checksum mismatch: $filename"
  }
}

Push-Location $repositoryRoot
$operationStopwatch = [Diagnostics.Stopwatch]::StartNew()
$restoreSucceeded = $false
$n8nWasRunning = $false
$containerTempCreated = $false
$containerTempDirectory = "/tmp/tcm-restore-$([guid]::NewGuid().ToString('N'))"
$n8nArchiveName = 'n8n-data.tar.gz'

try {
  if (-not (Test-Path '.env')) {
    throw 'The target .env file is required and must contain the original N8N_ENCRYPTION_KEY.'
  }

  Invoke-Compose -Arguments @('config', '--quiet')
  $runningServices = @(Invoke-Compose -Arguments @('ps', '--status', 'running', '--services'))
  if ($runningServices -notcontains 'postgres') {
    throw 'The target PostgreSQL service must be initialized and running.'
  }
  $n8nWasRunning = $runningServices -contains 'n8n'
  if ($n8nWasRunning) {
    Invoke-Compose -Arguments @('stop', 'n8n')
  }

  Invoke-Compose -Arguments @('exec', '-T', 'postgres', 'mkdir', '-m', '700', $containerTempDirectory)
  $containerTempCreated = $true
  Invoke-Compose -Arguments @(
    'cp', (Join-Path $resolvedBackup 'threat_claim_monitor.dump'),
    "postgres:$containerTempDirectory/threat_claim_monitor.dump"
  )
  Invoke-Compose -Arguments @(
    'cp', (Join-Path $resolvedBackup 'n8n.dump'),
    "postgres:$containerTempDirectory/n8n.dump"
  )

  foreach ($database in @('threat_claim_monitor', 'n8n')) {
    Invoke-Compose -Arguments @(
      'exec', '-T', 'postgres',
      'psql', '--username', $PostgresUser, '--dbname', 'postgres',
      '--set', 'ON_ERROR_STOP=1', '--command',
      "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '$database' AND pid <> pg_backend_pid();"
    )
    Invoke-Compose -Arguments @(
      'exec', '-T', 'postgres',
      'pg_restore', '--username', $PostgresUser, '--dbname', $database,
      '--clean', '--if-exists', '--no-owner', '--no-privileges', '--exit-on-error',
      "$containerTempDirectory/$database.dump"
    )
  }

  Invoke-Compose -Arguments @('create', 'n8n')
  Invoke-Compose -Arguments @(
    'cp', (Join-Path $resolvedBackup $n8nArchiveName),
    "n8n:/home/node/.n8n/$n8nArchiveName"
  )
  $extractCommand = "tar -xzf /home/node/.n8n/$n8nArchiveName -C /home/node/.n8n && rm -f /home/node/.n8n/$n8nArchiveName"
  Invoke-Compose -Arguments @(
    'run', '--rm', '--no-deps', '--user', 'node', '--entrypoint', 'sh',
    'n8n', '-c', $extractCommand
  )

  $restoredMigrations = @(
    (Get-DatabaseScalar -Database 'threat_claim_monitor' -Query 'SELECT version FROM schema_migrations ORDER BY version;') -split "`r?`n" |
      Where-Object { $_ }
  )
  if (($restoredMigrations -join "`n") -ne (@($manifest.schema_migrations) -join "`n")) {
    throw 'Restored migration history does not match the backup manifest.'
  }

  foreach ($property in $manifest.application_row_counts.PSObject.Properties) {
    $actualCount = [int64](
      Get-DatabaseScalar -Database 'threat_claim_monitor' -Query "SELECT count(*) FROM $($property.Name);"
    )
    if ($actualCount -ne [int64]$property.Value) {
      throw "Restored row count mismatch for table $($property.Name)."
    }
  }

  $restoreSucceeded = $true
  Write-Host 'Backup restore and manifest verification passed.' -ForegroundColor Green
  Write-Host "Restore duration: $([Math]::Round($operationStopwatch.Elapsed.TotalSeconds, 3)) seconds"
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
      Write-Warning 'Could not remove the bounded PostgreSQL restore temporary files.'
    }
  }
  Pop-Location

  if ($restoreSucceeded -and $n8nWasRunning) {
    Push-Location $repositoryRoot
    try {
      Invoke-Compose -Arguments @('start', 'n8n')
    }
    finally {
      Pop-Location
    }
  }
  elseif (-not $restoreSucceeded) {
    Write-Warning 'Restore did not complete. n8n remains stopped; correct the cause and repeat the full restore.'
  }
}
