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

## Channel configuration boundary

The database stores only the channel name and whether it is enabled. Webhook endpoints, SMTP passwords, Teams URLs, and other credentials belong in the execution platform credential store and must never be written to PostgreSQL, workflow exports, logs, or Git.

Webhook, email, and Teams dispatch, retry scheduling, dead-letter handling, and per-attempt response sanitization are later M4 increments.

## Validation

Static repository validation checks the contract, eligibility gates, idempotency mechanism, and absence of delivery calls. The PostgreSQL runtime test creates synthetic data inside a transaction, verifies one job per enabled channel, verifies replay idempotency and historical-evidence suppression, rejects an invalid payload, and rolls everything back.
