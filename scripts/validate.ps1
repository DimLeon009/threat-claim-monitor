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

  python scripts/test_ransomware_live_contract.py
  if ($LASTEXITCODE -ne 0) {
    throw 'Ransomware.live workflow contract validation failed.'
  }

  python scripts/test_ransomlook_contract.py
  if ($LASTEXITCODE -ne 0) {
    throw 'RansomLook workflow contract validation failed.'
  }

  python scripts/test_frenchbreaches_contract.py
  if ($LASTEXITCODE -ne 0) {
    throw 'FrenchBreaches RSS contract validation failed.'
  }

  python scripts/test_cross_source_correlation_contract.py
  if ($LASTEXITCODE -ne 0) {
    throw 'Cross-source correlation contract validation failed.'
  }

  python scripts/test_source_health_contract.py
  if ($LASTEXITCODE -ne 0) {
    throw 'Source health and orchestration contract validation failed.'
  }

  python scripts/test_matching_contract.py
  if ($LASTEXITCODE -ne 0) {
    throw 'Matching contract validation failed.'
  }

  python scripts/test_ai_contract.py
  if ($LASTEXITCODE -ne 0) {
    throw 'AI contract validation failed.'
  }

  python scripts/test_local_analysis_workflow_contract.py
  if ($LASTEXITCODE -ne 0) {
    throw 'Local-analysis workflow contract validation failed.'
  }

  python scripts/test_inference_provider_contract.py
  if ($LASTEXITCODE -ne 0) {
    throw 'Inference-provider contract validation failed.'
  }

  python scripts/test_foundry_workflow_contract.py
  if ($LASTEXITCODE -ne 0) {
    throw 'Foundry workflow contract validation failed.'
  }

  python scripts/test_inference_parity.py
  if ($LASTEXITCODE -ne 0) {
    throw 'Inference parity validation failed.'
  }

  python scripts/test_notification_outbox_contract.py
  if ($LASTEXITCODE -ne 0) {
    throw 'Notification outbox contract validation failed.'
  }

  python scripts/test_webhook_workflow_contract.py
  if ($LASTEXITCODE -ne 0) {
    throw 'Generic webhook workflow contract validation failed.'
  }

  python scripts/test_notification_producer_workflow_contract.py
  if ($LASTEXITCODE -ne 0) {
    throw 'Notification producer workflow contract validation failed.'
  }

  python scripts/test_email_workflow_contract.py
  if ($LASTEXITCODE -ne 0) {
    throw 'SMTP email workflow contract validation failed.'
  }

  python scripts/test_teams_workflow_contract.py
  if ($LASTEXITCODE -ne 0) {
    throw 'Teams Workflows contract validation failed.'
  }

  python scripts/test_end_to_end_demo_contract.py
  if ($LASTEXITCODE -ne 0) {
    throw 'End-to-end synthetic demo contract validation failed.'
  }

  python scripts/test_backup_restore_contract.py
  if ($LASTEXITCODE -ne 0) {
    throw 'Backup and restore contract validation failed.'
  }

  python scripts/test_failure_mode_suite_contract.py
  if ($LASTEXITCODE -ne 0) {
    throw 'Failure-mode suite contract validation failed.'
  }

  python scripts/test_retention_contract.py
  if ($LASTEXITCODE -ne 0) {
    throw 'Configurable retention contract validation failed.'
  }

  powershell -NoProfile -ExecutionPolicy Bypass -File scripts/test_failure_modes.ps1
  if ($LASTEXITCODE -ne 0) {
    throw 'Failure-mode runtime suite failed.'
  }

  powershell -NoProfile -ExecutionPolicy Bypass -File scripts/test_retention.ps1
  if ($LASTEXITCODE -ne 0) {
    throw 'Configurable retention runtime validation failed.'
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
