#!/bin/sh
set -eu

repository_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repository_root"

docker compose up -d --wait postgres
docker compose exec -T postgres psql \
  --username tcm_admin \
  --dbname threat_claim_monitor \
  --set ON_ERROR_STOP=on < scripts/test_analysis_provider_routing_contract.sql

echo 'Analysis provider routing runtime validation passed.'
