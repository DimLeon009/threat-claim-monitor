$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$temporaryEnvironment = $false
Push-Location $repositoryRoot
try {
  if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    throw 'Docker was not found. Install or start Docker Desktop, then rerun this validation.'
  }

  if (-not (Test-Path '.env')) {
    Copy-Item '.env.example' '.env'
    $temporaryEnvironment = $true
  }

  docker compose config --quiet
  if ($LASTEXITCODE -ne 0) {
    throw 'Docker Compose validation failed.'
  }

  python scripts/validate_source_fixtures.py
  if ($LASTEXITCODE -ne 0) {
    throw 'Source fixture validation failed.'
  }

  $migrationFiles = @(Get-ChildItem 'db/migrations' -File -Filter '*.sql')
  if ($migrationFiles.Count -eq 0) {
    throw 'At least one database migration is required.'
  }

  $invalidMigrationNames = @(
    $migrationFiles.Name | Where-Object { $_ -notmatch '^\d{3}_[a-z0-9_]+\.sql$' }
  )
  if ($invalidMigrationNames.Count -gt 0) {
    throw "Migration filenames must follow NNN_snake_case.sql. Invalid: $($invalidMigrationNames -join ', ')"
  }

  Write-Host 'Repository validation passed.' -ForegroundColor Green
}
finally {
  if ($temporaryEnvironment -and (Test-Path '.env')) {
    Remove-Item '.env'
  }
  Pop-Location
}
