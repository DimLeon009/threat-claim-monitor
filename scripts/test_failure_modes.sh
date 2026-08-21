#!/bin/sh
set -eu

repository_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repository_root"

contracts='scripts/test_cross_source_correlation_contract.sql
scripts/test_source_health_contract.sql
scripts/test_local_analysis_persistence.sql
scripts/test_provider_aware_analysis.sql
scripts/test_notification_outbox_contract.sql'

docker compose up -d --wait postgres

printf '%s\n' "$contracts" | while IFS= read -r contract; do
  echo "Running $contract"
  docker compose exec -T postgres psql \
    --username tcm_admin \
    --dbname threat_claim_monitor \
    --set ON_ERROR_STOP=on < "$contract"
done

echo 'Failure-mode runtime suite passed (5 transactional contracts).'
