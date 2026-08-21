# Failure-mode validation

The Milestone 6 failure-mode suite exercises the failure boundaries that must remain deterministic before a V1 release. It runs only repository-safe synthetic fixtures against PostgreSQL. Every database contract starts a transaction and ends with `ROLLBACK`, so no synthetic claim, analysis, source run, match, notification, or configuration change remains after validation.

## Runtime matrix

| Boundary | Injected or simulated failure | Expected behavior | Contract |
|---|---|---|---|
| Cross-source correlation | Unnormalizable observation and repeated correlation | Reject or skip the invalid observation, preserve valid work, and remain idempotent | `scripts/test_cross_source_correlation_contract.sql` |
| Source health | Consecutive failures, rejected response, disabled source, and later recovery | Derive degraded/disabled/healthy state without duplicate mutable health data | `scripts/test_source_health_contract.sql` |
| Local inference | Unavailable local model and invalid provenance | Store only the deterministic sanitized fallback; reject falsified provenance | `scripts/test_local_analysis_persistence.sql` |
| Cloud inference | Rate limit and provider-specific fallback | Persist an allow-listed failure and provider provenance without an implicit provider switch | `scripts/test_provider_aware_analysis.sql` |
| Notification delivery | Active and stale leases, unsafe response text, repeated delivery failure, and recovery | Prevent double claims, redact unsafe text, schedule bounded retries, enter dead-letter after five attempts, and requeue safely | `scripts/test_notification_outbox_contract.sql` |

The suite complements the adapter fixture tests for malformed HTTP/RSS payloads and timeouts, the workflow-export tests for sanitized error branches, and the isolated backup manifest verification. It does not intentionally stop PostgreSQL, n8n, Ollama, Foundry, SMTP, Teams, or a real webhook endpoint. Destructive infrastructure fault injection belongs in a disposable environment, not an operator's active local instance.

## Windows

With Docker Desktop running:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/test_failure_modes.ps1
```

The runner starts only PostgreSQL when necessary, waits for its health check, executes the five contracts with `ON_ERROR_STOP`, and leaves the existing Compose services running. It transports each SQL file as Base64 before decoding it inside the container, preventing Windows PowerShell 5 from corrupting UTF-8 French contract strings on a native pipeline.

## macOS, Linux, and CI

```sh
sh scripts/test_failure_modes.sh
```

CI creates an ephemeral Compose database, runs the suite, and removes the database volume even when validation fails. Local execution never removes volumes.

## Pass criteria

The final line must be:

```text
Failure-mode runtime suite passed (5 transactional contracts).
```

Any earlier PostgreSQL error fails the suite. Do not weaken an assertion to accommodate a failure without first determining whether the contract, migration, or documented behavior is wrong.
