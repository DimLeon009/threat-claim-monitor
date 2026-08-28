# FrenchBreaches RSS source contract

## Evaluation outcome

FrenchBreaches exposes two official RSS 2.0 feeds. Threat Claim Monitor uses only the incident feed at `https://frenchbreaches.com/feed.xml`; the general blog feed is outside the source contract.

The contract was evaluated on 20 August 2026 against the official site and live HTTP metadata without retaining response content. The incident feed returned HTTP 200 with `application/rss+xml`, 100 items, a four-hour cache lifetime, and a `Last-Modified` validator. A conditional request returned HTTP 304. Every observed item had a non-empty title, absolute link, unique GUID equal to the permalink, and parseable publication date.

The [FrenchBreaches project page](https://frenchbreaches.com/a-propos) states that its RSS feed is available for automatic publication tracking and data integration. Its [legal notice](https://frenchbreaches.com/mentions-legales) also protects the site's general text, graphics, logo, and structure from reproduction. The adapter therefore applies a strict minimization boundary: it retains only four RSS metadata fields needed for internal defensive monitoring and never stores or republishes descriptions, categories, articles, graphics, or personal-data-type lists.

## Retained contract

| RSS value | Adapter use |
|---|---|
| `title` | Declared victim display name |
| `guid` | Stable source event identifier and deduplication input |
| `link` | Public incident permalink; it must equal the GUID |
| `pubDate` | Publication and discovery timestamp |

The allow-list requires between 1 and 200 items, HTTPS permalinks on the FrenchBreaches host, unique GUIDs, bounded strings, valid dates from 2000 through at most one day in the future, and no control characters in titles. Any unknown RSS fields are discarded before PostgreSQL.

FrenchBreaches does not expose a consistently structured threat actor, victim domain, or verification state in the retained fields. These values remain `NULL` or use the normal unverified claim state. The adapter never derives them from descriptions, categories, article text, or model output. This deliberately limits cross-source merging when an actor is absent rather than risking an incorrect correlation.

## Identity, baseline, and polling

The source key is the SHA-256 digest of the stable GUID. PostgreSQL enforces uniqueness on `(source_id, source_key)`, so RSS replay cannot duplicate an observation.

The first successful collection establishes a silent historical baseline. Non-normalizable titles are counted and rejected before insertion without blocking usable items. Descriptions and categories are neither inserted nor hashed into retained payloads.

The source polling interval is 240 minutes to respect the observed four-hour HTTP cache. WF-00 checks both the database enable switch and whether the source is due before invoking WF-12. Clean installations keep the source disabled until an operator reviews the local runtime contract and explicitly enables it.

## Failure behavior

WF-12 uses three bounded RSS-read attempts and dedicated failure outputs. Persisted failures contain only one allow-listed code and a fixed sanitized message.

| Failure code | Persisted message |
|---|---|
| `fetch_failed` | `FrenchBreaches RSS request failed after bounded retries` |
| `response_validation_failed` | `FrenchBreaches RSS response rejected by contract validation` |
| `ingestion_failed` | `FrenchBreaches database ingestion failed` |

An incompatible RSS shape, missing required value, duplicate GUID, unexpected host, invalid date, or oversized feed fails closed. A WF-12 failure does not stop the ransomware.live or RansomLook branches.

## Deployment

Fresh installations apply migration 023 automatically. On an existing volume,
back up and apply it only when it is missing from `schema_migrations`. Then
import `n8n/workflows/wf-12-collect-frenchbreaches.json` and follow the complete
[workflow deployment guide](../operations/workflow-deployment.md). Assign the
local `PostgreSQL - Threat Claim Monitor` credential to the ingestion,
correlation, and sanitized-failure PostgreSQL nodes.

Import WF-00 separately. Assign the same PostgreSQL credential to `Check
FrenchBreaches due`, publish WF-12, and configure `Collect FrenchBreaches` to
call it. Environment-specific workflow and credential identifiers remain absent
from committed exports.

Enable the source only for the reviewed runtime test:

```sql
SELECT * FROM set_source_enabled(
  'frenchbreaches',
  true,
  'RSS contract runtime validation'
);
```

If validation fails, disable only this source while retaining its collection history:

```sql
SELECT * FROM set_source_enabled(
  'frenchbreaches',
  false,
  'RSS contract requires review'
);
```

Validate the repository contract with:

```sh
python3 scripts/test_frenchbreaches_contract.py
```

The committed XML fixtures use only `.invalid` hosts and synthetic names. No live title, description, category, victim value, response body, or personal data is repository evidence.

## Windows runtime validation

The first live WF-12 execution fetched and inserted 100 historical observations as a silent baseline. Correlation processed all 100 observations, created 98 claims and 100 links, and produced no organization match. The difference between claims and links reflects repeated bounded victim titles under the existing deterministic 45-day correlation contract; no RSS item was duplicated or discarded.

The first validation attempt rejected the live feed before ingestion because the n8n Code sandbox does not expose the global JavaScript `URL` constructor. The failure followed the intended fail-closed route and persisted only the sanitized response-validation code. The validator was corrected to use an exact HTTPS host expression compatible with the Code sandbox, without changing the database contract or accepting another host.

An immediate second WF-12 execution produced zero processed observations, claims, or links, confirming GUID-based idempotency. WF-00 was then tested while FrenchBreaches was not due and while temporarily due. The due execution called WF-12 and remained idempotent; the configured interval was restored to 240 minutes. A subsequent scheduled orchestration invoked ransomware.live and RansomLook, skipped FrenchBreaches because it was not due, and completed successfully.

Only aggregate counts and sanitized states are documented. No live RSS item, title, description, category, permalink, or response body is retained in the repository.
