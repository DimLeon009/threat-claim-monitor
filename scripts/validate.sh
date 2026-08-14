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

for migration in db/migrations/*.sql; do
  filename=$(basename "$migration")
  echo "$filename" | grep -Eq '^[0-9]{3}_[a-z0-9_]+\.sql$' || {
    echo "Invalid migration filename: $filename" >&2
    exit 1
  }
done

echo 'Repository validation passed.'

