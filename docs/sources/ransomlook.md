# RansomLook source contract

## Purpose

RansomLook is the secondary structured claim feed for Milestone 5. The adapter consumes the public `GET /api/posts?days=7` endpoint and preserves only the three public fields required by the internal observation contract.

The contract was checked on 19 August 2026 against the official API documentation and a live HTTP 200 response. The documentation example iterates a direct JSON array, while the observed endpoint returned an object containing a `posts` array. WF-11 deliberately supports both forms and rejects every other root shape.

No live response values are committed. Repository fixtures contain synthetic names only.

## Accepted response forms

The currently observed wrapper is:

```json
{
  "posts": [
    {
      "group_name": "example-group",
      "post_title": "Acme Example",
      "discovered": "2026-08-18T08:30:00Z"
    }
  ]
}
```

For compatibility with the official example, the same record array is also accepted directly. The adapter requires between 1 and 500 records and rejects missing, empty, or non-string required fields.

| Field | Adapter use |
|---|---|
| `post_title` | Required victim display name and strict domain candidate |
| `group_name` | Required threat-actor name |
| `discovered` | Required RansomLook discovery timestamp |

All additional response fields are discarded before database ingestion. A value that does not pass the existing strict domain normalizer remains only a victim name. A fully masked title that normalizes to no usable text is skipped and counted in collection metadata as `rejected_unmatchable_count`; it cannot block otherwise valid observations or enter matching.

## Stable identity and baseline

The source key is derived from the normalized victim name, normalized threat actor, and parsed discovery timestamp. PostgreSQL enforces uniqueness on `(source_id, source_key)`, so replaying a response cannot insert the same RansomLook observation twice.

The first successful collection establishes a silent RansomLook baseline. Its observations are stored with `is_historical = true`; later unseen source keys are non-historical. This increment stores observations only. Cross-source claim correlation and the `multi_source_observed` transition are implemented separately so the state change can be tested independently.

## Failure behavior

WF-11 uses a 10-second timeout, three bounded attempts, and dedicated error outputs. Raw HTTP responses, exception stacks, and database errors never enter persisted failure history.

| Failure code | Persisted message |
|---|---|
| `fetch_failed` | `RansomLook request failed after bounded retries` |
| `response_validation_failed` | `RansomLook response rejected by contract validation` |
| `ingestion_failed` | `RansomLook database ingestion failed` |

An incompatible root wrapper, invalid content type, oversized array, or missing required field fails closed without completing the source baseline.

## Deployment

Apply migration `018_ransomlook_ingestion.sql`, then import `n8n/workflows/wf-11-collect-ransomlook.json` into n8n. Assign the local `PostgreSQL - Threat Claim Monitor` credential to `Insert observations if new` and `Record sanitized failure`.

WF-11 is inactive and has no environment-specific workflow or credential identifier in the committed export. Run it manually before connecting it to WF-00. The first successful run should report `is_baseline = true`; replaying the same response should report `inserted_count = 0`.

Validate the repository contract with:

```sh
python3 scripts/test_ransomlook_contract.py
```

The official endpoint and response example are documented by [RansomLook](https://www.ransomlook.io/doc/). RansomLook states that its API content is available under CC BY 4.0; Threat Claim Monitor nevertheless retains only bounded public metadata required for defensive monitoring.

## Windows runtime validation

The first Windows smoke-test collection fetched 264 records, rejected two fully masked titles, inserted 262 historical observations, and established the silent baseline. An immediate second collection fetched 266 records and inserted only the two newly published usable observations with `is_baseline = false`. The 262 previously stored observations were not duplicated.

No live victim value, response body, external URL, or credential is retained as repository evidence. Only aggregate collection counts and generated collection-run identifiers were inspected during validation.
