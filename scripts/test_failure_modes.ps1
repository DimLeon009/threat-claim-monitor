$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$contracts = @(
  'scripts/test_cross_source_correlation_contract.sql',
  'scripts/test_source_health_contract.sql',
  'scripts/test_local_analysis_persistence.sql',
  'scripts/test_provider_aware_analysis.sql',
  'scripts/test_notification_outbox_contract.sql'
)

Push-Location $repositoryRoot
try {
  if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    throw 'Docker was not found. Install or start Docker Desktop, then rerun the failure-mode suite.'
  }

  docker compose up -d --wait postgres
  if ($LASTEXITCODE -ne 0) {
    throw 'PostgreSQL did not become healthy for failure-mode validation.'
  }

  foreach ($contract in $contracts) {
    Write-Host "Running $contract"
    $contractPath = (Resolve-Path $contract).Path
    $encodedContract = [Convert]::ToBase64String(
      [IO.File]::ReadAllBytes($contractPath)
    )
    $encodedContract |
      docker compose exec -T postgres sh -c `
        'base64 -d | psql --username tcm_admin --dbname threat_claim_monitor --set ON_ERROR_STOP=on'
    if ($LASTEXITCODE -ne 0) {
      throw "Failure-mode contract failed: $contract"
    }
  }

  Write-Host 'Failure-mode runtime suite passed (5 transactional contracts).' -ForegroundColor Green
}
finally {
  Pop-Location
}
