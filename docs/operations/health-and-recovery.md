# Health and recovery

## Purpose

This runbook describes safe diagnostic and recovery actions for the local V1 stack. It avoids destructive data operations and distinguishes application health from external-source health.

## Service health

```sh
docker compose ps
docker compose logs --tail 100 postgres
docker compose logs --tail 100 n8n
```

Expected state:

- PostgreSQL reports healthy;
- n8n remains running after PostgreSQL becomes healthy;
- <http://localhost:5678> responds locally;
- no PostgreSQL authentication loop appears in logs.

## Database verification

```sh
docker compose exec postgres psql --username tcm_admin --dbname threat_claim_monitor --command "SELECT version, applied_at FROM schema_migrations ORDER BY version;"
```

If `POSTGRES_USER` was changed in `.env`, use that value.

## Safe restart order

Restart one application service:

```sh
docker compose restart n8n
```

Restart the full stack while preserving volumes:

```sh
docker compose down
docker compose up -d
```

Do not add `--volumes`. Named volumes hold the n8n credential store and both PostgreSQL databases.

## Failure triage

| Symptom | First checks | Safe action |
|---|---|---|
| n8n does not start | PostgreSQL health and credentials | Correct `.env`, restart n8n |
| PostgreSQL is unhealthy | Logs, disk space, volume mount | Stop writes and preserve volume before deeper repair |
| Credentials cannot be decrypted | `N8N_ENCRYPTION_KEY` consistency | Restore the original key; do not recreate credentials blindly |
| Ollama unavailable | Host process and `/api/tags` | Use fallback path; restart Ollama independently |
| One source repeatedly fails | Last collection runs and schema errors | Disable only that source while investigating |
| Notifications remain pending | Channel credentials and endpoint response | Correct channel, then retry outbox jobs |
| Notifications reach dead-letter | Attempt history and sanitized errors | Resolve cause and explicitly requeue selected jobs |

## Source health model

An unavailable source does not mean the full platform is unhealthy. Health should be reported per source using:

- timestamp of last successful collection;
- consecutive failure count;
- response validation result;
- fetched and inserted record counts;
- observed schema version or contract fixture.

A source schema change should fail closed: reject unmappable records and alert the operator rather than guessing fields.

## Outbox recovery principles

- Never mark a notification as sent without an external send attempt.
- Never delete dead-letter records to hide failure.
- Retry only after correcting the cause.
- Preserve the stable alert ID and deduplication key.
- Expect a rare duplicate if a process crashes after external delivery but before recording success.

## Backup boundary

Before v1.0.0, the project will provide tested commands for:

- logical backup of both PostgreSQL databases;
- preservation of the n8n data volume and encryption key;
- restore into a clean environment;
- documented recovery-time observations.

Until that procedure is implemented, do not treat the development stack as the sole copy of important operational history.

## Escalation data

When reporting an issue, include:

- operating system and architecture;
- Docker and Compose versions;
- pinned n8n and PostgreSQL image versions;
- sanitized `docker compose ps` output;
- relevant bounded log excerpt;
- migration version;
- steps already attempted.

Never include `.env`, authorization headers, webhook URLs, raw stolen data, or unredacted personal information.

