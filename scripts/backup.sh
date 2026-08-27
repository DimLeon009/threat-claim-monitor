#!/bin/sh
set -eu

usage() {
  echo "Usage: sh scripts/backup.sh DESTINATION_DIRECTORY [POSTGRES_USER] [COMPOSE_PROJECT_NAME]" >&2
}

if [ "$#" -lt 1 ] || [ "$#" -gt 3 ]; then
  usage
  exit 2
fi

destination_directory=$1
postgres_user=${2:-tcm_admin}
compose_project_name=${3:-}

repository_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repository_root"

compose() {
  if [ -n "$compose_project_name" ]; then
    COMPOSE_PROJECT_NAME=$compose_project_name docker compose "$@"
  else
    docker compose "$@"
  fi
}

if ! command -v docker >/dev/null 2>&1; then
  echo "Docker was not found. Start Docker Desktop and try again." >&2
  exit 1
fi
if ! command -v python3 >/dev/null 2>&1; then
  echo "Python 3 is required to create the backup manifest." >&2
  exit 1
fi
if [ ! -f .env ]; then
  echo "The local .env file is required. It is not copied into the backup." >&2
  exit 1
fi

compose config --quiet
running_services=$(compose ps --status running --services)
if ! printf '%s\n' "$running_services" | grep -qx postgres; then
  echo "PostgreSQL must be running before a backup can be created." >&2
  exit 1
fi

n8n_was_running=false
if printf '%s\n' "$running_services" | grep -qx n8n; then
  n8n_was_running=true
fi

started_at=$(date +%s)
backup_name="tcm-backup-$(date -u +%Y%m%dT%H%M%SZ)"
case "$destination_directory" in
  /*) resolved_destination=$destination_directory ;;
  *) resolved_destination=$repository_root/$destination_directory ;;
esac
backup_directory=$resolved_destination/$backup_name
if [ -e "$backup_directory" ]; then
  echo "Backup target already exists: $backup_directory" >&2
  exit 1
fi
mkdir -p "$backup_directory"
chmod 700 "$backup_directory"

metadata_directory=$(mktemp -d "${TMPDIR:-/tmp}/tcm-backup-metadata.XXXXXX")
container_temp_directory="/tmp/tcm-backup-$(date -u +%Y%m%dT%H%M%SZ)-$$"
container_temp_created=false
n8n_archive_created=false
backup_succeeded=false
n8n_archive_name=n8n-data.tar.gz

cleanup() {
  exit_code=$?
  trap - EXIT INT TERM

  if [ "$container_temp_created" = true ]; then
    compose exec -T postgres rm -f \
      "$container_temp_directory/threat_claim_monitor.dump" \
      "$container_temp_directory/n8n.dump" >/dev/null 2>&1 || \
      echo "Warning: could not remove bounded PostgreSQL backup files." >&2
    compose exec -T postgres rmdir "$container_temp_directory" >/dev/null 2>&1 || true
  fi
  if [ "$n8n_archive_created" = true ]; then
    compose run --rm --no-deps --user node --entrypoint rm n8n \
      -f "/home/node/.n8n/$n8n_archive_name" >/dev/null 2>&1 || \
      echo "Warning: could not remove the bounded n8n backup archive." >&2
  fi
  if [ "$n8n_was_running" = true ]; then
    compose start n8n >/dev/null || \
      echo "Warning: n8n could not be restarted automatically." >&2
  fi
  rm -rf "$metadata_directory"

  if [ "$backup_succeeded" != true ]; then
    echo "Warning: backup did not complete. Do not use the incomplete backup directory." >&2
  fi
  exit "$exit_code"
}
trap cleanup EXIT INT TERM

if [ "$n8n_was_running" = true ]; then
  compose stop n8n
fi

compose exec -T postgres mkdir -m 700 "$container_temp_directory"
container_temp_created=true
for database in threat_claim_monitor n8n; do
  compose exec -T postgres pg_dump \
    --username "$postgres_user" \
    --dbname "$database" \
    --format custom \
    --no-owner \
    --no-privileges \
    --file "$container_temp_directory/$database.dump"
  compose cp "postgres:$container_temp_directory/$database.dump" \
    "$backup_directory/$database.dump"
done

compose up --no-start --no-deps --no-recreate n8n >/dev/null
archive_command="tar -czf /home/node/.n8n/$n8n_archive_name --exclude=./config --exclude=./$n8n_archive_name -C /home/node/.n8n ."
compose run --rm --no-deps --user node --entrypoint sh n8n -c "$archive_command"
n8n_archive_created=true
compose cp "n8n:/home/node/.n8n/$n8n_archive_name" \
  "$backup_directory/$n8n_archive_name"

compose exec -T postgres psql \
  --username "$postgres_user" \
  --dbname threat_claim_monitor \
  --tuples-only --no-align \
  --command 'SELECT version FROM schema_migrations ORDER BY version;' \
  > "$metadata_directory/migrations.txt"

: > "$metadata_directory/counts.txt"
for table in sources organizations collection_runs observations claims analyses notification_outbox notification_attempts; do
  count=$(compose exec -T postgres psql \
    --username "$postgres_user" \
    --dbname threat_claim_monitor \
    --tuples-only --no-align \
    --command "SELECT count(*) FROM $table;")
  printf '%s|%s\n' "$table" "$count" >> "$metadata_directory/counts.txt"
done

compose exec -T postgres psql \
  --username "$postgres_user" \
  --dbname threat_claim_monitor \
  --tuples-only --no-align \
  --command 'SHOW server_version;' \
  > "$metadata_directory/postgres-version.txt"

duration_seconds=$(( $(date +%s) - started_at ))
python3 - "$backup_directory" "$metadata_directory" "$duration_seconds" <<'PY'
import hashlib
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

backup = Path(sys.argv[1])
metadata = Path(sys.argv[2])
duration = int(sys.argv[3])
filenames = ("threat_claim_monitor.dump", "n8n.dump", "n8n-data.tar.gz")
files = {}
for filename in filenames:
    path = backup / filename
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    files[filename] = {"sha256": digest.hexdigest(), "bytes": path.stat().st_size}

migrations = [line for line in (metadata / "migrations.txt").read_text().splitlines() if line]
counts = {}
for line in (metadata / "counts.txt").read_text().splitlines():
    table, count = line.split("|", 1)
    counts[table] = int(count)

manifest = {
    "contract_version": "tcm-backup-v1",
    "created_at_utc": datetime.now(timezone.utc).isoformat(),
    "backup_duration_seconds": duration,
    "postgres_version": (metadata / "postgres-version.txt").read_text().strip(),
    "databases": ["threat_claim_monitor", "n8n"],
    "schema_migrations": migrations,
    "application_row_counts": counts,
    "n8n_volume": {
        "included": True,
        "config_excluded": True,
        "original_encryption_key_required": True,
    },
    "files": files,
}
(backup / "manifest.json").write_text(
    json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
)
PY

chmod 600 "$backup_directory"/*
backup_succeeded=true
echo "Backup created: $backup_directory"
echo "Backup duration: $duration_seconds seconds"
echo "Store this directory securely and preserve N8N_ENCRYPTION_KEY separately."
