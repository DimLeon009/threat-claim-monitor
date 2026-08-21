$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repositoryRoot = Split-Path -Parent $PSScriptRoot
Push-Location $repositoryRoot
try {
  if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    throw 'Docker was not found. Install or start Docker Desktop, then rerun retention validation.'
  }

  docker compose up -d --wait postgres
  if ($LASTEXITCODE -ne 0) {
    throw 'PostgreSQL did not become healthy for retention validation.'
  }

  $contractPath = (Resolve-Path 'scripts/test_retention_contract.sql').Path
  $encodedContract = [Convert]::ToBase64String(
    [IO.File]::ReadAllBytes($contractPath)
  )
  $encodedContract |
    docker compose exec -T postgres sh -c `
      'base64 -d | psql --username tcm_admin --dbname threat_claim_monitor --set ON_ERROR_STOP=on'
  if ($LASTEXITCODE -ne 0) {
    throw 'Configurable retention runtime validation failed.'
  }

  Write-Host 'Configurable retention runtime validation passed.' -ForegroundColor Green
}
finally {
  Pop-Location
}
