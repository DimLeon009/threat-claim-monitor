# 🗄️ Data model

## Purpose

The application schema preserves a traceable chain from external observation to analyst-facing notification. It is designed around evidence lineage, safe retries, and explicit uncertainty rather than a single flattened “incident” table.

Migration `001_initial_schema.sql` creates the foundation schema.

## Entity relationship overview

```mermaid
erDiagram
    SOURCES ||--o{ COLLECTION_RUNS : executes
    SOURCES ||--o{ OBSERVATIONS : produces
    COLLECTION_RUNS o|--o{ OBSERVATIONS : fetches
    CLAIMS ||--o{ CLAIM_OBSERVATIONS : groups
    OBSERVATIONS ||--|| CLAIM_OBSERVATIONS : linked_once
    ORGANIZATIONS ||--o{ ORGANIZATION_ALIASES : defines
    CLAIMS ||--o{ ORGANIZATION_MATCHES : evaluated_against
    ORGANIZATIONS ||--o{ ORGANIZATION_MATCHES : matched_by
    CLAIMS ||--o{ ANALYSES : summarized_by
    CLAIMS ||--o{ NOTIFICATION_OUTBOX : creates
    ORGANIZATIONS ||--o{ NOTIFICATION_OUTBOX : receives
    NOTIFICATION_OUTBOX ||--o{ NOTIFICATION_ATTEMPTS : records
```

## Configuration entities

### `sources`

Defines a collection adapter and its operational state.

Important fields:

- `slug`: stable machine identifier used by workflows;
- `source_kind`: `api`, `rss`, or `json`;
- `base_url`: adapter base endpoint;
- `enabled`: collection switch;
- `poll_interval_minutes`: requested cadence;
- `metadata`: non-secret source configuration and lifecycle notes.

Secrets never belong in `metadata` or migrations.

### `organizations`

Defines a monitored legal entity or brand.

- `normalized_name` is unique;
- `domains` contains approved registered domains;
- disabled organizations retain history but do not produce new matches.

### `organization_aliases`

Contains explicitly approved alternative names or domains. Each alias defines its matching mode and deterministic confidence score.

Aliases should be narrow. Generic terms, product names, and ambiguous abbreviations must not be auto-alert aliases.

## Evidence entities

### `collection_runs`

One record represents one source execution. It captures status, timing, fetched count, inserted count, diagnostic metadata, and a sanitized error.

Collection runs support source-health reporting without depending on short-lived n8n execution logs.

### `observations`

An observation is one source’s representation of a claim.

Key invariants:

- `(source_id, source_key)` is unique;
- every observation belongs to one source;
- original and normalized victim fields coexist;
- `payload_hash` identifies the normalized raw payload;
- `is_historical` prevents baseline notifications;
- an observation can link to only one canonical claim.

`raw_payload` contains only necessary public metadata. It must not contain downloaded leaked material or secrets.

### `claims`

A claim is the platform’s canonical grouping of one or more observations believed to describe the same publication event.

It contains:

- canonical victim and actor identity;
- first and last observation timestamps;
- optional claimed date;
- lifecycle state;
- verification state;
- monotonically increasing evidence version.

The canonical key supports correlation but is intentionally not globally unique. Republishing, corrections, and distinct events involving the same victim and actor remain possible.

### `claim_observations`

Provides evidence lineage between a canonical claim and source observations. The unique constraint on `observation_id` prevents one observation from supporting multiple claims simultaneously.

## Decision entities

### `organization_matches`

Stores the deterministic result of evaluating a claim against the watchlist.

The record includes:

- matching method;
- confidence score from 0 to 100;
- evidence explaining the rule;
- review status;
- review timestamp when applicable.

Model-generated text must never populate the matching method or confidence score.

### `analyses`

Stores a local-model result or deterministic fallback.

Reproducibility fields include:

- model name and optional digest;
- prompt version;
- input hash;
- structured output;
- validation status;
- sanitized error.

The uniqueness constraint prevents repeated analysis of the same claim, prompt version, and input.

## Delivery entities

### `notification_outbox`

Implements the transactional outbox pattern. A notification becomes eligible for external delivery only after its durable job exists.

The deduplication key combines the claim, organization, channel, notification type, and evidence version. Status values are:

- `pending`;
- `processing`;
- `sent`;
- `retry`;
- `dead_letter`.

### `notification_attempts`

Records every channel attempt, including timestamp, success, response status, bounded response excerpt, and sanitized error.

Response bodies must be truncated and must not persist authentication material.

## State invariants

1. Source observations are immutable evidence; corrections create new evidence or explicit state updates.
2. An observation belongs to at most one claim.
3. A match score is rule-derived and constrained to 0–100.
4. Verification state is separate from match confidence.
5. Evidence version increases when a material source or verification change should permit an update notification.
6. One logical notification key can exist only once.
7. External delivery attempts never delete their outbox parent.

## Retention

| Data | Initial policy |
|---|---|
| Sources, organizations, aliases | Retain while configuration or history references them |
| Claims and matches | Retain for project history |
| Normalized observations | Retain for history |
| Raw payload field | Minimize at ingestion; eligible for clearing after 180 days |
| Analyses | Retain with model and prompt provenance |
| Notification attempts | Retain for audit; review policy before production use |
| Successful n8n executions | 14 days |

Retention will become configurable before v1.0.0. Deletion must preserve referential integrity and the evidence required to explain sent alerts.

## Migration rules

- Migration names follow `NNN_snake_case.sql`.
- Applied migrations are never rewritten.
- Schema changes use transactions when PostgreSQL permits them.
- Migrations insert their version into `schema_migrations`.
- Constraints should enforce workflow assumptions whenever practical.
- Destructive migrations require backup, rollback, and compatibility notes.
- Seed records must contain no environment-specific secret.

## Future extensions

Possible additions include analyst comments, official confirmation evidence, source health snapshots, notification subscriptions, and retention jobs. IOC storage and vector embeddings are deliberately not part of this schema until their use cases are implemented.

