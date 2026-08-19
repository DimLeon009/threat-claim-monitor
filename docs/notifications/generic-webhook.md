# Generic webhook adapter

`WF-60 Dispatch generic webhook` is the first external notification adapter. It consumes only `notification-v1` jobs from the durable outbox and sends the complete JSON object with HTTPS `POST`.

## Security boundary

The committed export is inactive, contains an inert `example.invalid` URL, and contains no credential identifier. The live workflow must use an HTTPS endpoint whose path contains no password, token, signature, or other secret. Authentication belongs in an n8n **HTTP Header Auth** credential.

This adapter is intended for a conventional authenticated API endpoint. Do not place a Slack, Teams, or other secret-bearing webhook URL in it; those channels require their dedicated adapter and credential procedure.

## Import and configuration

1. Import `n8n/workflows/wf-50-build-notification-outbox.json` and `n8n/workflows/wf-60-dispatch-generic-webhook.json`.
2. Attach the existing PostgreSQL Threat Claim Monitor credential to the WF-50 PostgreSQL node and both WF-60 PostgreSQL nodes.
3. In `Send generic webhook`, replace the inert URL with the reviewed HTTPS endpoint.
4. Create or attach an n8n HTTP Header Auth credential required by the receiver.
5. Keep both workflows unpublished while testing manually.
6. Enable the database channel only after the URL and credential are ready:

```sql
UPDATE notification_channel_configs
SET enabled = true, updated_at = now()
WHERE channel = 'webhook';
```

7. Execute WF-50 manually to create jobs for eligible current analyses, then execute WF-60 and verify the outbox row becomes `sent` with one successful attempt.
8. Test one controlled failure and verify `retry` without creating another outbox row.
9. Publish WF-50 as `M4 notification outbox producer v1` and WF-60 as `M4 generic webhook adapter v1`.

Never export the live endpoint or credential assignment back into the repository. The sanitized repository export remains the review artifact.

## Delivery behavior

The workflow claims at most ten webhook jobs with a two-minute lease. The HTTP request has a ten-second timeout and performs no node-level retry; PostgreSQL owns retry scheduling and dead-letter state.

Successful responses and failures converge on `record_notification_delivery_result_envelope`. The database revalidates the job lease and result shape before atomically appending attempt history and changing outbox state. Transport failures are classified into allow-listed codes, and raw failure objects are not persisted.

External delivery is at-least-once. If n8n stops after the receiver accepts the request but before PostgreSQL records success, the expired lease permits another attempt. Receivers should treat `alert_id` as their idempotency key.

## Validation

`scripts/test_webhook_workflow_contract.py` checks the inactive sanitized export, fixed method and timeout, credential requirement, dedicated error branch, database-owned retry, JSON serialization, result persistence, and an escaping-oriented synthetic payload.
