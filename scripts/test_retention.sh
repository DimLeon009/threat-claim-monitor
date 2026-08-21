#!/bin/sh
set -eu

repository_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repository_root"

docker compose up -d --wait postgres
docker compose exec -T postgres psql \
  --username tcm_admin \
  --dbname threat_claim_monitor \
  --set ON_ERROR_STOP=on < scripts/test_retention_contract.sql

echo 'Configurable retention runtime validation passed.'
