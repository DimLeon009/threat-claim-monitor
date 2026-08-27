[CmdletBinding()]
param(
  [string]$ReportDirectory = 'security-reports'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$trivyImage = 'ghcr.io/aquasecurity/trivy:0.74.0@sha256:62b1e65e8869bc4b4c6aa4fa2b21595256c7c2f6018a9d9ad61caf87187c1969'
$images = [ordered]@{
  postgres = 'postgres:17.10-alpine3.23'
  n8n = 'docker.n8n.io/n8nio/n8n:2.36.7'
}

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
  throw 'Docker was not found. Start Docker Desktop and try again.'
}
if (-not (Get-Command python -ErrorAction SilentlyContinue)) {
  throw 'Python was not found.'
}

$resolvedReports = [IO.Path]::GetFullPath(
  (Join-Path $repositoryRoot $ReportDirectory)
)
[IO.Directory]::CreateDirectory($resolvedReports) | Out-Null
$reportMount = "$resolvedReports`:/reports"
$cacheDirectory = Join-Path $resolvedReports 'trivy-cache'
[IO.Directory]::CreateDirectory($cacheDirectory) | Out-Null
$cacheMount = "$cacheDirectory`:/root/.cache/trivy"

foreach ($entry in $images.GetEnumerator()) {
  $reportPath = Join-Path $resolvedReports "$($entry.Key).json"
  & docker run --rm --volume $reportMount `
    --volume $cacheMount `
    --volume '/var/run/docker.sock:/var/run/docker.sock' $trivyImage `
    image --cache-dir /root/.cache/trivy --skip-version-check --scanners vuln --format json `
    --severity UNKNOWN,LOW,MEDIUM,HIGH,CRITICAL `
    --output "/reports/$($entry.Key).json" $entry.Value
  if ($LASTEXITCODE -ne 0) {
    throw "Trivy failed to scan $($entry.Value)."
  }

  & python (Join-Path $PSScriptRoot 'evaluate_trivy_report.py') $reportPath `
    (Join-Path $repositoryRoot 'security/trivy-exceptions.json')
  if ($LASTEXITCODE -ne 0) {
    throw "Container security threshold failed for $($entry.Value)."
  }
}

Write-Host "Container image scans passed. Reports: $resolvedReports" -ForegroundColor Green
