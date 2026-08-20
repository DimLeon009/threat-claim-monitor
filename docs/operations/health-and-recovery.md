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

### Requeue one dead-letter notification

Inspect the job and its attempt history first, correct the channel credential or endpoint outside PostgreSQL, then requeue only the selected identifier:

```sql
SELECT requeue_dead_letter_notification('00000000-0000-4000-8000-000000000000');
```

The function refuses non-dead-letter jobs, reuses the existing outbox row, resets its delivery counter, and preserves all earlier attempt records. Replace the example UUID with the reviewed job identifier; never requeue an unbounded set of rows.

## Source health model

An unavailable source does not mean the full platform is unhealthy. Health should be reported per source using:

- timestamp of last successful collection;
- consecutive failure count;
- response validation result;
- fetched and inserted record counts;
- observed schema version or contract fixture.

A source schema change should fail closed: reject unmappable records and alert the operator rather than guessing fields.

An individual observation whose victim label normalizes to no usable text is skipped at the correlation boundary instead of failing the entire collection run. Inspect `correlation_skipped_unmatchable_count` in collection-run metadata when investigating discrepancies between inserted and correlated counts. Skipped observations remain retained as source evidence and never create claims, matches, analyses, or notifications.

Migration `021_source_health_and_switches.sql` exposes these indicators through the read-only `source_health` view. Inspect every configured source with:

```sql
SELECT
  slug,
  enabled,
  health_status,
  latest_status,
  last_success_at,
  consecutive_failure_count,
  latest_response_validation,
  latest_fetched_count,
  latest_inserted_count,
  latest_contract_version
FROM source_health
ORDER BY slug;
```

Health values are:

- `disabled`: intentionally excluded from orchestration;
- `never_run`: enabled but no collection history exists;
- `degraded`: the latest run failed or is partial, or failures followed the latest success;
- `stale`: no successful run occurred within three configured polling intervals;
- `healthy`: the latest state is successful and current.

### Enable or disable a source

Use the bounded database function rather than editing WF-00. A short non-secret reason is mandatory and retained in source metadata:

```sql
SELECT * FROM set_source_enabled(
  'ransomlook',
  false,
  'planned source maintenance'
);
```

Re-enable the source after review:

```sql
SELECT * FROM set_source_enabled(
  'ransomlook',
  true,
  'source contract revalidated'
);
```

The function rejects URLs and secret-like words in the reason. Do not place credentials, response bodies, personal data, or endpoint tokens in operational metadata.

WF-00 reads each source switch before invoking its collector. The ransomware.live and RansomLook branches are independent and use continue-on-error behavior at the sub-workflow boundary. A disabled source produces no collector execution, and a failed source does not prevent the other enabled branch from running.

FrenchBreaches adds a due-time check based on its configured 240-minute polling interval. This respects the official feed's observed four-hour cache while allowing WF-00 to keep its shared 15-minute schedule. A healthy but not-yet-due FrenchBreaches source produces no collector execution and is not a failure.

Windows runtime validation confirmed both due and not-due paths. The due branch invoked WF-12 without creating replay duplicates; after restoring the 240-minute interval, the next scheduled orchestration skipped FrenchBreaches while both JSON collectors completed. A prior RSS contract rejection remained isolated and sanitized, and the subsequent successful collection reset the source's consecutive-failure state.

### Windows runtime validation

The source-health contract was exercised transactionally against PostgreSQL, including degraded, disabled, recovered, and unsafe-reason rejection paths. The real health view distinguished an intentionally disabled experimental source, a stale source, and a source degraded by a partial correlation run.

That partial run contained 31 inserted observations. Migration `022_skip_unmatchable_correlation_observations.sql` allowed 30 usable observations to be correlated while retaining and safely skipping one non-normalizable label; the run recovered to `succeeded` without duplicate links. The cross-source correlation runtime contract then passed, including replay idempotency and the unmatchable-label case.

WF-00 was validated with both sources enabled, with RansomLook disabled, and again after re-enabling it. While RansomLook was disabled, ransomware.live continued successfully and the RansomLook collector was not invoked. A subsequent scheduled execution invoked both collectors and produced zero new links, confirming independent routing and idempotent replay.

## Outbox recovery principles

- Never mark a notification as sent without an external send attempt.
- Never delete dead-letter records to hide failure.
- Retry only after correcting the cause.
- Preserve the stable alert ID and deduplication key.
- Expect a rare duplicate if a process crashes after external delivery but before recording success.

## Backup boundary

The [backup and restore runbook](backup-and-restore.md) provides custom-format logical backups of both PostgreSQL databases, preservation of the non-secret n8n data volume, checksums, manifest verification, and an isolated restore exercise. The original n8n encryption key remains outside the backup and must be preserved separately.

Do not treat the local development stack or an unverified backup as the sole copy of important operational history.

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
