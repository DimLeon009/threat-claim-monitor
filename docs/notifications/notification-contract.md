# Notification contract and transactional outbox

Milestone 4 starts with a channel-independent `notification-v1` contract. PostgreSQL creates the durable outbox job in the same database transaction that selects the current claim, accepted organization match, eligible analysis, and non-historical evidence. This increment does not contact an external service.

## Eligibility

`enqueue_claim_notifications` only produces jobs when all of the following are true:

- the claim exists and is locked for the duration of the operation;
- the selected analysis belongs to the claim and covers its current evidence version;
- the analysis is `valid` or a validated deterministic `fallback`;
- at least one current, non-historical observation supports the claim;
- exactly one organization match is `accepted` or `auto_accepted`;
- the target channel is explicitly enabled in `notification_channel_configs`.

No accepted match or historical-only evidence produces no job. Multiple accepted organizations fail closed and require review.

## Common payload

Every job uses the strict `notification-v1` JSON shape:

- alert identifier, notification type, and creation timestamp;
- organization identifier and display name;
- claim identifier, evidence version, victim, actor, dates, and verification state;
- deterministic match method, confidence, and review state;
- analysis provider, deployment, model, validation state, French summary, observed facts, and uncertainties;
- one to ten source names and observation dates;
- the mandatory uncertainty disclaimer.

The contract rejects unknown top-level and nested fields. It contains neither raw source payloads nor source URLs. Endpoint, authorization, API key, token, and secret material are forbidden.

## Idempotency and concurrency

The claim row is selected `FOR UPDATE`, serializing concurrent producers for that claim. The stable deduplication key combines contract version, claim, organization, channel, notification type, and evidence version. Its unique constraint plus `ON CONFLICT DO NOTHING` ensures that retries and replays return the existing job instead of creating a duplicate.

New evidence may increment `evidence_version`, allowing a new status-change or correction notification while preserving prior delivery history.

WF-50 calls `enqueue_ready_claim_notifications` once per minute. The database selects only current eligible analyses and deterministically prefers a valid result over a fallback. An enabled Microsoft Foundry configuration gives its stored result precedence; otherwise the local Ollama result is preferred. Selection never invokes an inference provider. Claims whose enabled-channel jobs already exist are skipped, while the underlying unique keys remain the final concurrency guard.

## Channel configuration boundary

The database stores only the channel name and whether it is enabled. Webhook endpoints, SMTP passwords, Teams URLs, and other credentials belong in the execution platform credential store and must never be written to PostgreSQL, workflow exports, logs, or Git.

The generic webhook network adapter is implemented by WF-60. Email and Teams network dispatch remain later M4 increments.

## Concurrent job reservation

Migration 014 adds a bounded lease to each outbox job. A worker calls `claim_notification_jobs` for exactly one allow-listed channel and receives at most 100 eligible jobs. PostgreSQL selects jobs with `FOR UPDATE SKIP LOCKED`, so concurrent workers cannot reserve the same row.

Pending and retry jobs become eligible only when `available_at` is reached. A processing job can be reclaimed only after its lease expires. Reclaiming generates a new unpredictable lease token; the previous worker must therefore not be allowed to record a delivery result with its stale token. Lease duration is constrained to 30–900 seconds.

The migration safely returns any pre-existing unleased `processing` row to `retry`. External delivery is still absent from this increment.

## Delivery results, retry, and dead-letter

Migration 015 atomically verifies the active lease, appends one `notification_attempts` row, and moves the outbox job to its next state. An expired, stale, or incorrect lease token cannot record a result.

A successful attempt moves the job to `sent` and records `sent_at`. A failure accepts only an allow-listed error code translated to a fixed message. Response excerpts are limited to 500 characters, control characters are removed, and content resembling a URL, credential, authorization value, password, secret, or token is replaced with `[redacted unsafe response]`.

Failures retry after an exponential delay starting at 60 seconds and capped at one hour. The fifth failed attempt moves the same durable job to `dead_letter`; it never creates another outbox row. An operator can call `requeue_dead_letter_notification` after correcting the cause. Requeue resets the delivery counter but preserves the complete attempt history.

## Generic webhook adapter

WF-60 claims only the `webhook` channel, serializes the common payload with `JSON.stringify`, and sends it through a ten-second HTTPS request with n8n HTTP Header Auth. The node performs no direct retry. Both success and the dedicated sanitized failure output bind one strict JSON result envelope to PostgreSQL.

See the [generic webhook runbook](generic-webhook.md) for safe import, configuration, testing, and publication.

## Validation

Static repository validation checks the contract, eligibility gates, idempotency mechanism, concurrent lease operation, result finalization, and absence of delivery calls. The PostgreSQL runtime test creates synthetic data inside a transaction and verifies job production, replay idempotency, lease exclusivity and recovery, bounded retry, dead-letter, manual requeue, sanitized attempt history, successful finalization, historical-evidence suppression, and invalid-payload rejection before rolling everything back.
