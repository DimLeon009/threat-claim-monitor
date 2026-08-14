#!/bin/sh
set -eu

# The official PostgreSQL image runs this file only when creating a fresh volume.
psql --set ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-'EOSQL'
SELECT format('CREATE DATABASE threat_claim_monitor OWNER %I', current_user)
WHERE NOT EXISTS (
  SELECT FROM pg_database WHERE datname = 'threat_claim_monitor'
)
\gexec
EOSQL

for migration in /migrations/*.sql; do
  [ -e "$migration" ] || continue
  echo "Applying $migration"
  psql --set ON_ERROR_STOP=1 \
    --username "$POSTGRES_USER" \
    --dbname threat_claim_monitor \
    --file "$migration"
done
