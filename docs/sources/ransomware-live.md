# ransomware.live source contract

## Purpose

`ransomware.live` is the primary structured claim feed for Milestone 1. The adapter consumes the public `GET /v2/recentvictims` endpoint and treats every returned field as untrusted data.

The endpoint returned a JSON array of 100 records when the contract was checked on 14 August 2026. Live response values are not committed to the repository.

## Observed response fields

| Field | Observed type | Adapter use |
|---|---|---|
| `victim` | string | Required victim display name |
| `group` | string | Required threat-actor name |
| `domain` | string | Optional victim domain candidate |
| `attackdate` | string | Optional claimed attack date |
| `discovered` | string | Required source discovery timestamp |
| `description` | string | Optional untrusted description |
| `url` | string | Preferred aggregator evidence URL |
| `claim_url` | string | Optional claim URL; never fetched automatically |
| `activity`, `country` | string | Optional public metadata |
| `data_size`, `press`, `ransom`, `screenshot`, `infostealer` | mixed | Not required for matching or control decisions |

The adapter must fail closed when the response root is not an array or when a record lacks `victim`, `group`, or `discovered`. Optional empty values remain unknown and must not be invented.

## Stable identity

The source key is derived only from normalized source fields:

```text
sha256(lower(trim(victim)) + "\n" + lower(trim(group)) + "\n" + trim(discovered))
```

The database uniqueness constraint on `(source_id, source_key)` provides the final duplicate guard. The payload hash is calculated separately from the normalized, allow-listed raw payload so later evidence changes can be detected without changing record identity.

## Silent baseline

The first successful collection stores all accepted records with `is_historical = true`. The source baseline is complete only after the full response has been validated and the collection run succeeds.

Later collections use `is_historical = false` for newly observed source keys. Historical records cannot enter the new-claim notification path.

## Safety and fixture policy

- The adapter fetches only the configured HTTPS API endpoint.
- URLs contained in records are stored as evidence and are never followed automatically.
- Descriptions can contain prompt-injection text and remain untrusted data.
- Logs contain bounded validation errors, not full source payloads.
- Tests use `fixtures/ransomware-live/recent-victims.synthetic.json` only.
- Fixture hostnames use the reserved `.invalid` domain and contain no real victim data.

Validate the fixture with:

```sh
python3 scripts/validate_source_fixtures.py
```

## Workflow deployment

Fresh installations apply every migration automatically. For an existing
volume, back up first, then apply every missing migration in numeric order; do
not skip migrations 004 through 006 or rewrite an applied file. For example:

```sh
docker compose exec postgres psql \
  --username tcm_admin \
  --dbname threat_claim_monitor \
  --file /migrations/002_ransomware_live_ingestion.sql

docker compose exec postgres psql \
  --username tcm_admin \
  --dbname threat_claim_monitor \
  --file /migrations/003_ransomware_live_failure_history.sql

docker compose exec postgres psql \
  --username tcm_admin \
  --dbname threat_claim_monitor \
  --file /migrations/004_matching_normalization.sql

# Continue with 005 and 006, then:
docker compose exec postgres psql \
  --username tcm_admin \
  --dbname threat_claim_monitor \
  --file /migrations/007_collection_run_correlation.sql
```

Import `n8n/workflows/wf-10-collect-ransomware-live.json` and `n8n/workflows/wf-00-orchestrator.json` into n8n. Assign the local `PostgreSQL - Threat Claim Monitor` credential to `Insert observations if new`, `Correlate collection observations`, `Record sanitized failure`, and `Record sanitized correlation failure`; credentials and environment-specific credential identifiers are intentionally absent from the committed export.

In `WF-00 Orchestrator`, configure `Collect ransomware.live` to call `WF-10 Collect ransomware.live` and assign the PostgreSQL credential to its enable gate. Migration 021 adds a parallel RansomLook gate and collector branch. Database workflow and credential identifiers are intentionally absent from the committed export because they are local to each n8n instance.

Both exports remain inactive after import. Run `WF-10` manually to establish and
inspect the baseline, publish it so WF-00 can call it, then test and publish
WF-00. WF-10 does not own a schedule. See the complete
[workflow deployment guide](../operations/workflow-deployment.md).

## Processing path

1. `Fetch recent victims` calls the configured endpoint with a 10-second timeout and at most three attempts.
2. `Validate and allow-list response` requires HTTP 200, JSON content, a bounded array, and the three required string fields.
3. Only allow-listed public metadata reaches PostgreSQL.
4. `ingest_ransomware_live_collection` serializes collections for this source, creates a run, inserts unseen source keys, and completes the baseline atomically.
5. A duplicate source key is a no-op and increments neither `observations` nor `inserted_count`.
6. `correlate_collection_run_exact` processes the observations inserted by that collection run and persists its sanitized summary.

## Failure behavior

HTTP exhaustion, response-contract rejection, and database-ingestion errors leave the success path through a dedicated n8n error output. The workflow replaces the raw error item with one allow-listed code before calling `record_ransomware_live_failure`:

| Failure code | Persisted message |
|---|---|
| `fetch_failed` | `ransomware.live request failed after bounded retries` |
| `response_validation_failed` | `ransomware.live response rejected by contract validation` |
| `ingestion_failed` | `ransomware.live database ingestion failed` |

The failure record contains zero fetched and inserted items, the contract version, and the allow-listed code. It never stores the raw response, exception stack, connection string, or credential. After persistence, `Stop with sanitized failure` fails the n8n execution with only the sanitized message.

Correlation errors use a separate guarded output. `record_claim_correlation_failure` changes the already successful ingestion run to `partial`, stores only `correlation_failed` and the bounded message `claim correlation failed; retry the collection run correlation`, then stops the workflow. The original database error is not persisted or forwarded by the sanitized stop node.

Validate the failure-routing contract with:

```sh
python3 scripts/test_ransomware_live_contract.py
```

The test covers malformed response fixtures, required-field rejection, timeout and retry settings, error-output routing, allow-listed classification, and sanitized termination.
