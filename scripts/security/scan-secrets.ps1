[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$gitleaksImage = 'ghcr.io/gitleaks/gitleaks:v8.30.1@sha256:c00b6bd0aeb3071cbcb79009cb16a60dd9e0a7c60e2be9ab65d25e6bc8abbb7f'

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
  throw 'Docker was not found. Start Docker Desktop and try again.'
}
if (-not (Test-Path (Join-Path $repositoryRoot '.git'))) {
  throw 'Secret scanning requires a complete local Git repository.'
}

$mount = "$repositoryRoot`:/repo:ro"
& docker run --rm --volume $mount $gitleaksImage `
  git --redact=100 --no-banner --no-color --verbose --timeout=300 `
  --log-opts=--all /repo
if ($LASTEXITCODE -ne 0) {
  throw 'Secret history scan failed. Treat every finding as sensitive and rotate confirmed credentials.'
}

Write-Host 'Secret history scan passed.' -ForegroundColor Green
