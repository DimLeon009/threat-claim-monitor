# End-to-end synthetic demonstration

This M6 scenario proves the complete application path without representing a real incident and without contacting a real notification recipient. It creates a uniquely marked source, organization, collection run, and observation; then it exercises the production correlation, exact matching, analysis persistence, notification outbox, webhook delivery, and audit contracts.

For a short reviewer-facing sequence and the mandatory screenshot-sanitization
rules, follow the [V1 release demonstration guide](release-demonstration.md).

The scenario is deliberately separate from public-source fixtures. Every inserted row carries the marker `m6-end-to-end-v1`, the organization is named `TCM Synthetic Demo Organization`, and the receiver rejects any other organization.

## Safety boundary

- Run this only on a local development database.
- Do not replace the synthetic names with real organizations or victims.
- The enqueue script temporarily selects only the webhook channel inside one PostgreSQL transaction and restores all channel switches before commit.
- The dispatch preflight fails closed if another webhook job is dispatchable.
- The receiver requires an n8n Header Auth credential and returns only a bounded acknowledgement.
- Cleanup uses fixed UUIDs and refuses to delete a claim containing non-demo evidence.

## One-time n8n setup

Import `n8n/workflows/wf-99-receive-synthetic-demo.json`. Create one local
Header Auth credential with a random value, attach that credential to `Receive
synthetic notification`, publish and activate the workflow, and keep the
production URL local:

```text
http://localhost:5678/webhook/tcm-synthetic-demo
```

In `WF-60 Dispatch generic webhook`, temporarily set `Send generic webhook` to
that exact URL and attach the same Header Auth credential object. Explicitly
replace both sanitized placeholders: the imported export deliberately contains
the inert `webhook.example.invalid` URL and no usable credential assignment.
Save WF-60 after selecting the URL and credential, but keep it unpublished and
execute it only manually. Do not commit the credential assignment or edited
endpoint. Pause the scheduled triggers for WF-50 and WF-60 while running the
demonstration manually.

Inside the n8n container, `localhost:5678` addresses n8n itself. The host UI may still be exposed on another port such as `15678`.

Before creating the outbox job, verify in the n8n editor that WF-60 no longer
references `webhook.example.invalid` or a deleted credential. A failure recorded
as `notification credential is unavailable` means the node still references a
missing credential ID. `getaddrinfo ENOTFOUND webhook.example.invalid` means the
sanitized URL was not replaced. Correct and save both fields before restarting
the synthetic scenario; do not repeatedly dispatch the same retry job while
configuration is unresolved.

## Run the scenario on Windows

From PowerShell at the repository root, seed the observation and exercise correlation plus deterministic exact matching:

```powershell
Get-Content -Raw scripts/demo/seed_end_to_end.sql |
  docker compose exec -T postgres psql --username tcm_admin --dbname threat_claim_monitor
```

For a dependency-free demonstration, persist the contract-valid deterministic fallback analysis:

```powershell
Get-Content -Raw scripts/demo/store_deterministic_analysis.sql |
  docker compose exec -T postgres psql --username tcm_admin --dbname threat_claim_monitor
```

Alternatively, run WF-40 first to exercise the local Ollama path. The fallback script reuses an already eligible analysis instead of replacing it.

Create exactly one webhook outbox job while preserving the current channel switches:

```powershell
Get-Content -Raw scripts/demo/enqueue_webhook_notification.sql |
  docker compose exec -T postgres psql --username tcm_admin --dbname threat_claim_monitor
```

Run the dispatch safety check:

```powershell
Get-Content -Raw scripts/demo/preflight_webhook_dispatch.sql |
  docker compose exec -T postgres psql --username tcm_admin --dbname threat_claim_monitor
```

If it passes, execute WF-60 manually once. WF-99 must receive one request and return HTTP 202. Then verify the persisted delivery evidence:

```powershell
Get-Content -Raw scripts/demo/verify_end_to_end.sql |
  docker compose exec -T postgres psql --username tcm_admin --dbname threat_claim_monitor
```

The final line must be `End-to-end synthetic M6 demonstration passed.`

## Validated Windows result

The scenario was exercised successfully on Windows 11 on 20 August 2026. One non-historical synthetic observation created one claim, one `domain_exact` match with confidence 100 and `auto_accepted` review status, one contract-valid deterministic fallback analysis, and one webhook notification. The authenticated local receiver acknowledged exactly one request; the outbox recorded `sent` after one attempt. No real source, organization, victim, or notification destination was used.

## Cleanup

After capturing evidence that passes the release guide's sanitization review,
remove only the demonstration rows:

```powershell
Get-Content -Raw scripts/demo/cleanup_end_to_end.sql |
  docker compose exec -T postgres psql --username tcm_admin --dbname threat_claim_monitor
```

Restore the original WF-60 endpoint after the test and resume only the scheduled workflows that were active before the demonstration. No database migration is required because this scenario adds no production schema or permanent reference data.
