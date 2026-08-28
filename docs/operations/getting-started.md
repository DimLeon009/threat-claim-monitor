# Getting started

## Supported development platforms

- Windows 11 with Docker Desktop
- macOS on Apple Silicon with Docker Desktop

The Compose services use multi-architecture images. PostgreSQL is intentionally not published to the host network. n8n is bound to localhost only.

## 1. Configure secrets

Copy `.env.example` to `.env` and replace the placeholder values.

Windows:

```powershell
Copy-Item .env.example .env
```

macOS or Linux:

```sh
cp .env.example .env
```

PowerShell can generate a suitable value:

```powershell
$bytes = New-Object byte[] 32
[Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
[Convert]::ToHexString($bytes).ToLower()
```

Generate separate values for `POSTGRES_PASSWORD` and `N8N_ENCRYPTION_KEY`. Never commit `.env`. Keep the n8n encryption key stable: losing it makes stored n8n credentials unreadable.

## 2. Validate configuration

Windows:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/validate.ps1
```

macOS or Linux:

```sh
sh scripts/validate.sh
```

## 3. Start the platform

```sh
docker compose up -d
docker compose ps
```

Open <http://localhost:5678> and create the n8n owner account.

On the first start, PostgreSQL creates the `n8n` and `threat_claim_monitor` databases and applies all migrations currently present in `db/migrations`.

### Reproduce a clean Windows first start

The release validation can create and remove a separate Compose project without
changing the active installation:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/test_windows_installation.ps1
```

The isolated project uses fresh volumes and port `25678` by default. It verifies
database initialization, migrations, seed data, n8n health and version, and host
network exposure, then removes only its own temporary resources. Pass
`-N8nPort <unused-port>` when the default test port is unavailable.

## 4. Verify the application database

```powershell
docker compose exec postgres psql --username tcm_admin --dbname threat_claim_monitor --command "SELECT version, applied_at FROM schema_migrations ORDER BY version;"
```

If `POSTGRES_USER` was changed, replace `tcm_admin` in this command.

## 5. Ollama preparation

Ollama is not required for Milestone 0. For later milestones it will run on the host:

```sh
ollama pull qwen3:8b-q4_K_M
```

The configured endpoint is `http://host.docker.internal:11434` from n8n.

## Applying migrations after first start

PostgreSQL initialization scripts run only for a new volume. Until a dedicated migration job is introduced, apply a new migration explicitly:

```powershell
docker compose exec postgres psql --username tcm_admin --dbname threat_claim_monitor --file /migrations/NNN_migration_name.sql
```

Migrations must be idempotent where practical and must insert their version into `schema_migrations`.

## Stop and backup

Stop containers without deleting data:

```sh
docker compose down
```

Do not use `docker compose down --volumes` unless intentionally deleting the local PostgreSQL and n8n data. Backup and restore procedures will be formalized before v1.0.0.
