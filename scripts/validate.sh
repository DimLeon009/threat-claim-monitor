#!/bin/sh
set -eu

repository_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repository_root"

temporary_environment=false
cleanup() {
  if [ "$temporary_environment" = true ]; then
    rm -f .env
  fi
}
trap cleanup EXIT

if [ ! -f .env ]; then
  cp .env.example .env
  temporary_environment=true
fi

docker compose config --quiet

python3 scripts/validate_source_fixtures.py
python3 scripts/test_ransomware_live_contract.py
python3 scripts/test_ransomlook_contract.py
python3 scripts/test_frenchbreaches_contract.py
python3 scripts/test_cross_source_correlation_contract.py
python3 scripts/test_source_health_contract.py
python3 scripts/test_matching_contract.py
python3 scripts/test_ai_contract.py
python3 scripts/test_local_analysis_workflow_contract.py
python3 scripts/test_inference_provider_contract.py
python3 scripts/test_foundry_workflow_contract.py
python3 scripts/test_inference_parity.py
python3 scripts/test_notification_outbox_contract.py
python3 scripts/test_webhook_workflow_contract.py
python3 scripts/test_notification_producer_workflow_contract.py
python3 scripts/test_email_workflow_contract.py
python3 scripts/test_teams_workflow_contract.py

for migration in db/migrations/*.sql; do
  filename=$(basename "$migration")
  echo "$filename" | grep -Eq '^[0-9]{3}_[a-z0-9_]+\.sql$' || {
    echo "Invalid migration filename: $filename" >&2
    exit 1
  }
done

echo 'Repository validation passed.'
