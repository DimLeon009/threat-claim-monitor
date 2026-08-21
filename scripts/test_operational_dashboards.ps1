$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repositoryRoot = Split-Path -Parent $PSScriptRoot
Push-Location $repositoryRoot
try {
  if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    throw 'Docker was not found. Install or start Docker Desktop, then rerun operational dashboard validation.'
  }

  docker compose up -d --wait postgres
  if ($LASTEXITCODE -ne 0) {
    throw 'PostgreSQL did not become healthy for operational dashboard validation.'
  }

  $contractPath = (Resolve-Path 'scripts/test_operational_dashboards_contract.sql').Path
  $encodedContract = [Convert]::ToBase64String(
    [IO.File]::ReadAllBytes($contractPath)
  )
  $encodedContract |
    docker compose exec -T postgres sh -c `
      'base64 -d | psql --username tcm_admin --dbname threat_claim_monitor --set ON_ERROR_STOP=on'
  if ($LASTEXITCODE -ne 0) {
    throw 'Operational dashboards runtime validation failed.'
  }

  Write-Host 'Operational dashboards runtime validation passed.' -ForegroundColor Green
}
finally {
  Pop-Location
}
