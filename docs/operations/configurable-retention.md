# Configurable retention

The V1 retention policy is deliberately conservative. It can remove only old,
terminal collection-run records that have no linked observation. It never
automatically removes observations, claims, source links, organization matches,
analyses, notification jobs, or notification attempts.

## Safety rules

- Retention is disabled by default.
- The retention window is bounded between 7 and 3,650 days.
- Each execution is bounded between 1 and 10,000 deleted collection runs.
- A run linked to any observation is always preserved.
- The latest run, latest successful run, and latest failed or partial run for
  every source are preserved for health diagnostics.
- Running collection jobs are never eligible.
- An advisory lock prevents concurrent retention jobs.
- Successful executions write only a sanitized policy snapshot and deletion
  count to `retention_runs`.

The default policy is disabled with a 90-day window and a maximum of 1,000 rows
per execution.

## Apply and validate migration 024

Apply the new migration once to an existing environment:

```powershell
docker compose exec -T postgres psql `
  --username tcm_admin `
  --dbname threat_claim_monitor `
  --file /migrations/024_configurable_retention.sql
```

Run the transactionally isolated contract:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/test_retention.ps1
```

The expected final line is `Configurable retention runtime validation passed.`

## Preview before enabling

Inspect the current policy and eligible row count without deleting anything:

```sql
SELECT * FROM retention_policy;
SELECT * FROM preview_retention_job();
```

Configure a reviewed window while keeping the job disabled:

```sql
SELECT * FROM set_retention_policy(false, 90, 1000);
SELECT * FROM preview_retention_job();
```

Only after reviewing the preview, enable the policy:

```sql
SELECT * FROM set_retention_policy(true, 90, 1000);
```

Disable it immediately without changing its other settings:

```sql
SELECT * FROM set_retention_policy(false, 90, 1000);
```

## WF-70 setup

Import `n8n/workflows/wf-70-configurable-retention.json`, then attach the
`PostgreSQL - Threat Claim Monitor` credential to both PostgreSQL nodes.

Run `Preview retention manually` first. This path calls only
`preview_retention_job()` and cannot delete data. The scheduled path calls
`run_retention_job()` once per day at 03:15 in `Europe/Paris`.

Keep WF-70 unpublished until the preview, the configured policy, and the
database backup posture have been reviewed. Publishing WF-70 does not override
the database switch: when the policy is disabled, the scheduled job returns
`disabled` and deletes zero rows.

## n8n execution logs

n8n execution-history pruning is separate from application-data retention. Its
defaults remain 336 hours and 10,000 executions and can be overridden in `.env`:

```dotenv
N8N_EXECUTIONS_DATA_MAX_AGE_HOURS=336
N8N_EXECUTIONS_DATA_PRUNE_MAX_COUNT=10000
```

Restart n8n after changing these values. Do not treat n8n execution history as
the durable audit record; durable application evidence remains in PostgreSQL.

## Rollback

Do not edit migration 024 after it has been applied. Disable the policy first.
If the schema objects must be removed or replaced, create a later forward-only
migration. Take and verify a backup before any destructive rollback migration.
