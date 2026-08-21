# Operational dashboards

The operational dashboards provide a read-only view of source collection and
notification delivery health. They deliberately expose aggregate state rather
than source payloads, claim content, raw errors, endpoint details, credentials,
lease tokens, or notification bodies.

## Database views

Migration `025_operational_dashboards.sql` adds three views:

| View | Purpose |
|---|---|
| `operational_dashboard_summary` | One-row overview of source and channel attention counts |
| `operational_source_dashboard` | Per-source health, collection timing, counts, and sanitized failure classification |
| `operational_notification_dashboard` | Per-channel backlog, retry, processing, expired-lease, sent, and dead-letter counts |

The views do not store a duplicate operational state. They derive their results
from `source_health`, collection history, notification channel configuration,
the outbox, and notification attempt timestamps.

## Source classification

| Attention level | Meaning |
|---|---|
| `inactive` | The source is explicitly disabled |
| `ok` | The enabled source is healthy |
| `warning` | Collection has never run, is overdue, or has fewer than three consecutive failures |
| `critical` | The enabled source has at least three consecutive failed or partial runs |

The dashboard exposes only allow-listed failure codes and fixed classifications.
It does not expose `collection_runs.error_message`.

## Notification classification

| Health status | Meaning |
|---|---|
| `disabled` | The channel is explicitly disabled |
| `healthy` | No current delivery attention is required |
| `backlog` | At least one pending or retry job is ready |
| `degraded` | At least one retry is scheduled for later |
| `critical` | At least one job is in dead-letter or has an expired processing lease |

Dead-letter and expired-lease conditions take precedence over other states.
The dashboard never exposes payloads, destination details, deduplication keys,
raw response excerpts, error messages, or lease tokens.

## Apply and validate migration 025

Apply the migration once to an existing environment:

```powershell
docker compose exec -T postgres psql `
  --username tcm_admin `
  --dbname threat_claim_monitor `
  --file /migrations/025_operational_dashboards.sql
```

Run the transactionally isolated contract:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/test_operational_dashboards.ps1
```

The expected final line is
`Operational dashboards runtime validation passed.`

## Direct SQL inspection

```sql
SELECT * FROM operational_dashboard_summary;
SELECT * FROM operational_source_dashboard ORDER BY slug;
SELECT * FROM operational_notification_dashboard ORDER BY channel;
```

Investigate `warning`, `critical`, `backlog`, and `degraded` rows using the
existing health-and-recovery procedures. A dashboard state is diagnostic; it
must not automatically requeue a notification, enable a source, or delete data.

## WF-71 setup

Import `n8n/workflows/wf-71-operational-dashboards.json`. Attach the
`PostgreSQL - Threat Claim Monitor` credential to its three PostgreSQL nodes.

The workflow has only a manual trigger and three fixed `SELECT` queries. It
does not need to be published or activated to serve as an operator dashboard.
Execute `Refresh dashboards manually`, then inspect:

- `Load operational summary`;
- `Load source dashboard`;
- `Load channel dashboard`.

Keep the committed workflow export inactive and free of credential identifiers.

## Rollback

Migration 025 is additive and must not be edited after application. If the views
must be changed or removed, create a later forward-only migration. Removing the
views does not change their underlying collection or notification records.
