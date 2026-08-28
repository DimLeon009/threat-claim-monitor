# Getting started

This guide creates a local development installation. It starts PostgreSQL and
n8n, verifies the database, and then points to the separate workflow deployment
guide. A fresh n8n database contains **no Threat Claim Monitor workflows or
credentials**: `docker compose up` alone does not finish the application setup.

## Supported development platforms

- Windows 11 with Docker Desktop;
- macOS on Apple Silicon with Docker Desktop;
- Git and Python 3 for repository validation;
- Ollama only when the local inference provider is selected.

The Compose images support both AMD64 and ARM64. PostgreSQL is not published to
the host network, and n8n listens on the host loopback interface only.

## 1. Clone and inspect the repository

```sh
git clone https://github.com/DimLeon009/threat-claim-monitor.git
cd threat-claim-monitor
git status
```

Expected result: branch `main` and a clean working tree.

Check the required tools:

```sh
git --version
python3 --version
docker version
docker compose version
```

On Windows, `python --version` may be used when `python3` is unavailable.

## 2. Configure the local environment

Copy the example without editing or committing the example itself.

Windows PowerShell:

```powershell
Copy-Item .env.example .env
notepad .env
```

macOS or Linux:

```sh
cp .env.example .env
${EDITOR:-vi} .env
```

Replace every `change-me-...` value. Generate **two independent values** for
`POSTGRES_PASSWORD` and `N8N_ENCRYPTION_KEY`; never reuse one value for both.

PowerShell generator:

```powershell
$bytes = New-Object byte[] 32
[Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
[Convert]::ToHexString($bytes).ToLower()
```

macOS or Linux generator:

```sh
openssl rand -hex 32
```

Run the generator twice. Never commit `.env`. Preserve `N8N_ENCRYPTION_KEY` in
an approved password manager: losing it makes existing n8n credentials
unreadable. Change `N8N_PORT` only when the default host port is occupied; the
container itself always listens on port 5678.

## 3. Validate before starting

Windows:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/validate.ps1
```

macOS or Linux:

```sh
sh scripts/validate.sh
```

The full validation may start PostgreSQL to run transactional contracts. The
last line must be `Repository validation passed.` Fix any earlier failure before
continuing.

## 4. Start the platform

```sh
docker compose up -d
docker compose ps
```

Wait until PostgreSQL is `healthy` and n8n is `Up`. If `N8N_PORT=5678`, open
<http://localhost:5678>; otherwise use the configured port. Create the first n8n
owner account and keep its password outside the repository.

On a new PostgreSQL volume, initialization creates both databases, applies all
26 migrations in `db/migrations`, and seeds three source definitions plus the
synthetic organization watchlist. Every bundled organization is visibly marked
`[Synthetic]` and uses a reserved `.invalid` domain. Replace this demonstration
configuration locally before monitoring an approved organization. Initialization
does not import n8n workflows or create n8n credentials.

Useful checks:

```sh
docker compose ps
docker compose logs --tail 100 postgres
docker compose logs --tail 100 n8n
```

### Isolated Windows first-start test

This test creates and removes a separate Compose project without modifying the
active installation:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/test_windows_installation.ps1
```

It uses fresh volumes and port `25678` by default. Pass
`-N8nPort <unused-port>` when that port is unavailable.

## 5. Verify the application database

Replace `tcm_admin` if `POSTGRES_USER` was changed:

```sh
docker compose exec postgres psql --username tcm_admin --dbname threat_claim_monitor --command "SELECT count(*) AS applied_migrations FROM schema_migrations;"
docker compose exec postgres psql --username tcm_admin --dbname threat_claim_monitor --command "SELECT slug, enabled FROM sources ORDER BY slug;"
```

Expected results on this revision:

- `applied_migrations` is `26`;
- the sources are `frenchbreaches`, `ransomlook`, and `ransomware-live`;
- a disabled source is not a failed installation.

## 6. Deploy the workflows

Continue with [Workflow deployment](workflow-deployment.md). It explains how to
create the PostgreSQL credential, import all workflow exports, connect the five
sub-workflows in WF-00, establish silent baselines, and publish only the intended
workflows.

For local inference, also follow the
[local analysis contract](../ai/local-analysis-contract.md). Microsoft Foundry
is optional and must be selected explicitly.

## Applying later migrations to an existing volume

Initialization scripts run only for a new PostgreSQL volume. Before applying a
new release to an existing installation:

1. create and verify a [backup](backup-and-restore.md);
2. compare `schema_migrations` with `db/migrations`;
3. apply every missing migration once, in numeric order;
4. never edit or re-run an already applied migration to change its meaning.

Example for one missing migration:

```sh
docker compose exec postgres psql --username tcm_admin --dbname threat_claim_monitor --file /migrations/NNN_migration_name.sql
```

## Stop, restart, and update

Stop without deleting data:

```sh
docker compose down
```

Restart:

```sh
docker compose up -d
```

Never use `docker compose down --volumes` as a routine command: it deletes the
local PostgreSQL and n8n volumes. Back up before image, schema, or stateful
maintenance and follow the release-specific migration notes.

For another machine or server, do not expose the current stack directly. Read
[Remote administration](remote-administration.md) first. For installation or
runtime problems, use [Health and recovery](health-and-recovery.md) and then the
[support routing guide](../../SUPPORT.md).
