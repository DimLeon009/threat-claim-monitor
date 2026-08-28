# Transactional claim correlation

## Purpose

`correlate_observation_exact` turns one stored observation into durable domain state in a single PostgreSQL transaction. It creates or reuses a claim, links the observation exactly once, advances the evidence version, and persists deterministic organization matches.

The function never sends a notification. Historical-baseline suppression remains
available on the linked observation and is enforced by the implemented WF-50
notification producer and database eligibility contract.

## Correlation key and window

Candidates must have the same normalized threat actor and either:

- the same normalized victim name; or
- the same normalized candidate domain.

The observation time uses the first available value from claimed publication time, source discovery time, fetch time, and creation time. A candidate claim is eligible when that time falls no more than 45 days before its first evidence or after its last evidence.

If no claim is eligible, the function creates a new canonical claim. If one is eligible, the observation is linked to it. If legacy or manually edited data produces more than one eligible claim, the function fails closed with a sanitized ambiguity error and writes nothing.

## Concurrency and replay

The V1 single-host deployment uses one transaction-scoped advisory lock for claim correlation. This deliberately serializes the small correlation workload so concurrent observations cannot create overlapping claims through different source keys or name/domain variants.

`claim_observations.observation_id` remains unique. Replaying an already linked observation returns its existing claim without incrementing `evidence_version` or duplicating matches. A newly linked observation increments the claim evidence version once.

## Match persistence

Exact candidates from `find_exact_organization_matches` are inserted into `organization_matches` with their rule evidence and source observation ID. Higher-confidence deterministic evidence can replace an unreviewed lower-confidence method. Human `accepted` or `rejected` decisions are never overwritten.

If a claim accumulates matches for multiple organizations, all non-reviewed matches become `pending` with collision evidence and `auto_alert_eligible = false`.

## Runtime validation

Apply migrations through `006_transactional_claim_correlation.sql`, then run the transaction-safe synthetic test:

```sh
docker compose exec -T postgres psql \
  --username tcm_admin \
  --dbname threat_claim_monitor \
  --file /workspace/scripts/test_correlation_contract.sql
```

The reference Compose file does not mount the repository at `/workspace`; on a host, pipe or copy the SQL file into `psql`. The test wraps all synthetic observations, claims, matches, and collision configuration in `BEGIN`/`ROLLBACK`.

It validates replay idempotency, the 45-day boundary, actor separation, evidence-version increments, score-100 domain persistence, and fail-closed collision handling.

## Collection workflow integration

Migration `007_collection_run_correlation` adds `correlate_collection_run_exact`. The wrapper processes every observation inserted under one ransomware.live `collection_run_id`, calls the single-observation transaction for each item in stable order, and records bounded counters in `collection_runs.metadata`.

`WF-10 Collect ransomware.live` calls the wrapper immediately after successful ingestion. Replaying the same collection run is safe: existing observation links do not advance evidence versions. If correlation fails, `record_claim_correlation_failure` marks the collection run `partial` with one allow-listed message and no raw database error. A successful retry restores the run to `succeeded`.

Validate the wrapper with `scripts/test_collection_run_correlation_contract.sql`. Like the single-observation test, it rolls back all synthetic state.
