# SMTP email adapter

`WF-61 Dispatch SMTP email` consumes `email` jobs from the shared notification outbox and sends a bounded multipart email through n8n's SMTP credential.

## Repository-safe export

The committed workflow is inactive and contains no credential identifier, SMTP host, username, password, or real email address. Sender and recipient use the reserved `example.invalid` domain. Replace them only in the live n8n workflow.

SMTP host, port, encryption mode, username, and password belong exclusively in an n8n SMTP credential. TLS certificate validation remains enabled. The workflow contains no attachments, remote image, tracking pixel, or hyperlink, and disables n8n's external attribution link.

## Rendering contract

Every message includes both plain-text and HTML alternatives. The subject removes control characters and is limited to 160 characters. Bodies are bounded and contain:

- alert and organization identifiers;
- victim and threat actor;
- observation dates and verification state;
- deterministic match method and confidence;
- grounded summary, observed facts, and uncertainties;
- source names and dates only;
- mandatory uncertainty disclaimer.

All dynamic HTML values escape ampersands, angle brackets, double quotes, and single quotes. The plain-text renderer removes control characters before adding its own line structure. Raw payloads, source URLs, files, and criminal download links are absent.

## Import and configuration

1. Import `n8n/workflows/wf-61-dispatch-smtp-email.json`.
2. Attach `PostgreSQL - Threat Claim Monitor` to `Claim email jobs` and `Persist email delivery result`.
3. Create an n8n SMTP credential using an approved test or sandbox mailbox. Require TLS and do not allow unauthorized certificates.
4. Attach it only to `Send SMTP email`.
5. Replace the `example.invalid` sender and recipient with approved test addresses.
6. Keep WF-61 unpublished and keep the database `email` channel disabled until the credential test succeeds.
7. Enable the channel only for the controlled smoke test:

```sql
UPDATE notification_channel_configs
SET enabled = true, updated_at = now()
WHERE channel = 'email';
```

8. Run WF-50, then WF-61 manually. Confirm delivery, one `sent` outbox row, and one successful attempt.
9. Disable the channel again until operational recipients and ownership are approved.

Do not paste SMTP passwords, authentication headers, or full credential screenshots into issues, pull requests, execution evidence, or chat.

## Delivery behavior

WF-61 claims at most ten email jobs with a two-minute lease. The SMTP node performs no independent retry. PostgreSQL records either fixed `smtp accepted` success evidence or an allow-listed failure category; raw SMTP errors are not persisted. Retry, dead-letter, stale-lease rejection, and manual requeue use the common M4 database contract.

External delivery remains at-least-once. The subject and body include the stable alert identifier so recipients can recognize a repeated delivery after an uncertain handoff.

## Validation

`scripts/test_email_workflow_contract.py` checks the inactive sanitized export, installed Send Email node version, credential boundary, TLS settings, absence of attachments and links, bounded text and HTML rendering, HTML escaping fixture, dedicated error branch, and transactional result persistence.
