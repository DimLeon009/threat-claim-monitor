# Microsoft Teams Workflows adapter

`WF-62 Dispatch Teams Workflows` consumes `teams` jobs from the shared outbox and posts one bounded Adaptive Card to the Microsoft Teams Workflows webhook trigger.

## Supported contract

The adapter follows Microsoft's incoming-webhook envelope:

- outer type `message`;
- one attachment with `application/vnd.microsoft.card.adaptive`;
- Adaptive Card schema version 1.2;
- no action, button, image, mention entity, URL, or HTML.

The card contains the stable alert identifier, organization, victim, actor, verification state, deterministic match, dates, grounded analysis, observed facts, uncertainties, sources, and disclaimer. Every dynamic string is bounded, control characters are removed, Markdown punctuation is escaped, and angle brackets are replaced so source text cannot create formatting, links, or `<at>` mentions.

Microsoft documents the Adaptive Card envelope and Workflows webhook setup in [Create and send actionable messages](https://learn.microsoft.com/en-us/microsoftteams/platform/webhooks-and-connectors/how-to/connectors-using) and [Create incoming webhooks with Workflows](https://support.microsoft.com/en-us/teams/apps-service/create-incoming-webhooks-with-workflows-for-microsoft-teams).

## Webhook ownership and authentication

For the local prototype, create the Teams Workflow in a dedicated test channel using the `Anyone` trigger mode. Microsoft classifies this mode as unauthenticated, so the generated URL and its signature must be treated as a secret. Do not add an Authorization header to this trigger mode.

Before production use:

- assign at least one reviewed co-owner so the flow does not become orphaned;
- document the target team and channel owner;
- review whether tenant or specific-user OAuth authentication can replace `Anyone`;
- rotate the webhook URL after suspected disclosure;
- never paste the URL or signature into chat, screenshots, issues, execution evidence, PostgreSQL, or Git.

Microsoft documents the available authentication modes and their token requirements in the [Teams connector reference](https://learn.microsoft.com/en-gb/connectors/teams/).

## Repository-safe URL split

The committed HTTP node contains only an inert `example.invalid` URL. If the generated test URL has a single `sig` query parameter:

1. keep the non-secret URL portion and non-secret query parameters in the live WF-62 HTTP node;
2. remove `sig` from that URL;
3. create an n8n **HTTP Query Auth** credential named `Microsoft Teams Workflow signature`;
4. set its query parameter name to `sig` and its value to the signature only;
5. attach that credential to `Send Teams Adaptive Card`.

If the generated URL does not contain one separable `sig` parameter, stop rather than storing the full secret URL in the workflow. Use an approved tenant-authenticated design or another secret-management boundary.

## Import and smoke test

1. Import `n8n/workflows/wf-62-dispatch-teams-workflows.json`.
2. Attach `PostgreSQL - Threat Claim Monitor` to `Claim Teams jobs` and `Persist Teams delivery result`.
3. Apply the repository-safe URL split and attach the query credential.
4. Keep WF-62 unpublished and the database `teams` channel disabled.
5. Create the Workflow in a dedicated Teams sandbox channel and confirm its ownership settings.
6. Enable only the Teams channel for the controlled test:

```sql
UPDATE notification_channel_configs
SET enabled = (channel = 'teams'), updated_at = now();
```

7. Run WF-50, then WF-62 manually.
8. Confirm exactly one card appears, its text remains literal, and PostgreSQL records `sent` with one successful attempt.
9. Remove synthetic records and disable the channel after verification.

Publish only after the sanitized export, ownership, destination, secret storage, and runtime evidence have been reviewed.

## Delivery behavior

WF-62 claims at most ten jobs with a two-minute lease and uses a ten-second HTTP timeout. The HTTP node performs no independent retry. Success stores only a fixed acknowledgement; failure maps the status or transport category to an allow-listed code without persisting the raw provider response.

Delivery remains at-least-once. The stable alert identifier appears prominently so a duplicate caused by an uncertain network handoff can be recognized.

## Validation

`scripts/test_teams_workflow_contract.py` verifies the inactive sanitized export, official Adaptive Card envelope, v1.2 schema, absence of actions and external content, Markdown and mention neutralization corpus, credential split, dedicated error branch, database-owned retry, and transactional result persistence.
