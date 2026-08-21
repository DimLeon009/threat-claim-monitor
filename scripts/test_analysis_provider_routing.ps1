$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repositoryRoot = Split-Path -Parent $PSScriptRoot
Push-Location $repositoryRoot
try {
  if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    throw 'Docker was not found. Install or start Docker Desktop, then rerun analysis routing validation.'
  }

  docker compose up -d --wait postgres
  if ($LASTEXITCODE -ne 0) {
    throw 'PostgreSQL did not become healthy for analysis routing validation.'
  }

  $contractPath = (Resolve-Path 'scripts/test_analysis_provider_routing_contract.sql').Path
  $encodedContract = [Convert]::ToBase64String(
    [IO.File]::ReadAllBytes($contractPath)
  )
  $encodedContract |
    docker compose exec -T postgres sh -c `
      'base64 -d | psql --username tcm_admin --dbname threat_claim_monitor --set ON_ERROR_STOP=on'
  if ($LASTEXITCODE -ne 0) {
    throw 'Analysis provider routing runtime validation failed.'
  }

  Write-Host 'Analysis provider routing runtime validation passed.' -ForegroundColor Green
}
finally {
  Pop-Location
}
