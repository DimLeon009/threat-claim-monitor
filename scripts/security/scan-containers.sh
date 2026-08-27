#!/bin/sh
set -eu

repository_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
report_directory=${1:-"$repository_root/security-reports"}
trivy_image='ghcr.io/aquasecurity/trivy:0.74.0@sha256:62b1e65e8869bc4b4c6aa4fa2b21595256c7c2f6018a9d9ad61caf87187c1969'

mkdir -p "$report_directory"
cache_directory="$report_directory/trivy-cache"
mkdir -p "$cache_directory"

scan_image() {
  name=$1
  image=$2
  docker run --rm \
    --volume "$report_directory:/reports" \
    --volume "$cache_directory:/root/.cache/trivy" \
    --volume /var/run/docker.sock:/var/run/docker.sock \
    "$trivy_image" \
    image --cache-dir /root/.cache/trivy --skip-version-check --scanners vuln --format json \
    --severity UNKNOWN,LOW,MEDIUM,HIGH,CRITICAL \
    --output "/reports/$name.json" "$image"
  python3 "$repository_root/scripts/security/evaluate_trivy_report.py" \
    "$report_directory/$name.json" \
    "$repository_root/security/trivy-exceptions.json"
}

scan_image postgres 'postgres:17.10-alpine3.23'
scan_image n8n 'docker.n8n.io/n8nio/n8n:2.36.7'

echo "Container image scans passed. Reports: $report_directory"
