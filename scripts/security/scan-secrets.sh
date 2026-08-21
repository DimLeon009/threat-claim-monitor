#!/bin/sh
set -eu

repository_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
gitleaks_image='ghcr.io/gitleaks/gitleaks:v8.30.1@sha256:c00b6bd0aeb3071cbcb79009cb16a60dd9e0a7c60e2be9ab65d25e6bc8abbb7f'

docker run --rm \
  --volume "$repository_root:/repo:ro" \
  "$gitleaks_image" \
  git --redact=100 --no-banner --no-color --verbose --timeout=300 \
  --log-opts=--all /repo

echo 'Secret history scan passed.'
