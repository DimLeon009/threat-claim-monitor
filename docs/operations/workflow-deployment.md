# Deploy the n8n workflows

Docker Compose starts n8n and PostgreSQL, but a fresh n8n database intentionally
contains no workflows and no credentials. Repository exports are sanitized and
inactive: environment-specific workflow IDs and credential assignments are not
committed. Complete this guide after the services are healthy and the n8n owner
account exists.

## Safety defaults

- The ransomware.live and RansomLook sources are enabled in PostgreSQL.
- FrenchBreaches, every notification channel, and retention are disabled by
  default.
- Every committed workflow export is inactive.
- The initial successful run of each source is a silent historical baseline.
- Publishing an n8n workflow can activate its schedule. Publish only in the
  order documented below.

## 1. Create the PostgreSQL credential

In n8n, open **Credentials**, create a **Postgres** credential, and name it
`PostgreSQL - Threat Claim Monitor`.

| Field | Value |
|---|---|
| Host | `postgres` |
| Database | `threat_claim_monitor` |
| User | the `POSTGRES_USER` value from `.env` |
| Password | the `POSTGRES_PASSWORD` value from `.env` |
| Port | `5432` |
| SSL | disabled for the internal Compose network |

Test and save the credential. Do not use `localhost`: from the n8n container,
PostgreSQL is reached by its Compose service name `postgres`.

## 2. Import the workflow exports

Use **Workflows → Import from file** and import each required JSON file. Import
the callable sub-workflows before the orchestrator:

| Order | Export | Imported workflow | Purpose |
|---:|---|---|---|
| 1 | `wf-10-collect-ransomware-live.json` | `WF-10 Collect ransomware.live` | Primary collector |
| 2 | `wf-11-collect-ransomlook.json` | `WF-11 Collect RansomLook` | Secondary collector |
| 3 | `wf-12-collect-frenchbreaches.json` | `WF-12 Collect FrenchBreaches RSS` | Optional RSS collector |
| 4 | `wf-40-local-analysis.json` | `WF-40 Local analysis` | Ollama analysis |
| 5 | `wf-41-microsoft-foundry-analysis.json` | `WF-41 Microsoft Foundry analysis` | Optional cloud analysis |
| 6 | `wf-00-orchestrator.json` | `WF-00 Orchestrator` | Collection and analysis schedules |
| 7 | `wf-50-build-notification-outbox.json` | `WF-50 Build notification outbox` | Notification producer |
| 8 | `wf-60-dispatch-generic-webhook.json` | `WF-60 Dispatch generic webhook` | Optional webhook dispatcher |
| 9 | `wf-61-dispatch-smtp-email.json` | `WF-61 Dispatch SMTP email` | Optional email dispatcher |
| 10 | `wf-62-dispatch-teams-workflows.json` | `WF-62 Dispatch Teams Workflows` | Optional Teams dispatcher |
| 11 | `wf-70-configurable-retention.json` | `WF-70 Configurable retention` | Optional retention job |
| 12 | `wf-71-operational-dashboards.json` | `WF-71 Operational dashboards` | Manual read-only dashboard |
| 13 | `wf-99-receive-synthetic-demo.json` | `WF-99 Receive synthetic demo webhook` | Synthetic demo receiver only |

The minimal local collection path still imports WF-10, WF-11, WF-12, WF-40,
WF-41, and WF-00 because WF-00 contains explicit sub-workflow references for
both provider routes and all three source gates. Optional workflows may remain
unpublished after import.

## 3. Assign database credentials and sub-workflows

Assign `PostgreSQL - Threat Claim Monitor` to every PostgreSQL node in each
imported workflow. Then open WF-00 and configure these five **Execute
Sub-workflow** nodes:

| WF-00 node | Imported target |
|---|---|
| `Collect ransomware.live` | `WF-10 Collect ransomware.live` |
| `Collect RansomLook` | `WF-11 Collect RansomLook` |
| `Collect FrenchBreaches` | `WF-12 Collect FrenchBreaches RSS` |
| `Run local analysis` | `WF-40 Local analysis` |
| `Run Foundry analysis` | `WF-41 Microsoft Foundry analysis` |

Save every workflow. If n8n reports an unpublished referenced workflow, publish
the named sub-workflow first; do not bypass the dependency warning.

## 4. Prepare exactly one analysis provider

The default route is `ollama`. For local mode, install Ollama on the host, pull
the pinned model, and verify its digest before scheduling analysis:

```sh
ollama pull qwen3:8b-q4_K_M
python3 scripts/check_ollama.py
```

On Windows, use `python` if `python3` is not available. WF-40 needs only the
PostgreSQL credential; its local HTTP endpoint contains no secret.

Microsoft Foundry is optional. Configure its non-secret database row and the
`Microsoft Foundry API key` n8n credential only by following the [inference
provider contract](../ai/inference-providers.md). Never select Foundry merely
because Ollama is unavailable. Confirm the selected route:

```powershell
docker compose exec -T postgres psql `
  --username tcm_admin `
  --dbname threat_claim_monitor `
  --command "SELECT * FROM get_analysis_routing_decision();"
```

Replace `tcm_admin` if `POSTGRES_USER` differs.

## 5. Establish the silent baselines

Keep WF-00 unpublished. Execute WF-10 manually once and confirm it succeeds.
Then execute WF-11 manually once and confirm it succeeds. On a new database,
each result must report `is_baseline = true`; historical observations do not
enter notification eligibility.

FrenchBreaches remains disabled on a clean install. Configure and test it only
through its [source contract](../sources/frenchbreaches.md), then enable it with
the bounded database function if desired.

If a collector fails, stop here. Follow [health and
recovery](health-and-recovery.md) and do not publish the orchestrator until the
failure is understood.

## 6. Publish the safe core

Publish the five callable sub-workflows first: WF-10, WF-11, WF-12, WF-40, and
WF-41. WF-12 remains harmless while its database source switch is disabled;
WF-41 receives no jobs unless Foundry is both configured and selected.

Execute WF-00 manually and verify:

- both enabled JSON collectors complete independently;
- FrenchBreaches is skipped while disabled or not due;
- exactly the selected analysis workflow is called;
- the unselected provider is not called.

Publish WF-00 only after this check. Its collectors run every 15 minutes and its
exclusive analysis route runs every minute.

## 7. Add optional operations deliberately

- Keep all notification workflows unpublished until one channel is configured,
  tested, and enabled according to the relevant [notification
  documentation](../README.md#notifications).
- Publish WF-50 only when notification production is intended.
- Publish only the dispatcher whose channel is enabled.
- Keep WF-70 unpublished until a backup exists and retention preview has been
  reviewed. The database policy remains an independent safety switch.
- WF-71 has only a manual trigger and does not need publication.
- Publish WF-99 only for the bounded synthetic demonstration, then disable or
  archive it afterward.

## 8. Final installation check

Confirm the services:

```sh
docker compose ps
docker compose logs --tail 50 n8n
```

In n8n, confirm that no node shows a missing credential or missing sub-workflow.
Then inspect the application state:

```powershell
docker compose exec -T postgres psql `
  --username tcm_admin `
  --dbname threat_claim_monitor `
  --command "SELECT slug, enabled, health_status FROM source_health ORDER BY slug;"
```

Expected initial behavior is not “an alert immediately.” Baselines are silent,
notification channels are disabled, and only later unseen observations that
match the watchlist can progress toward an alert.

## Upgrade note

Workflow imports do not apply database migrations. Fresh volumes receive every
migration automatically. For an existing volume, back up first, inspect
`schema_migrations`, and apply each missing migration exactly once in numeric
order before importing workflows that depend on it. Never edit or casually
re-run an already applied migration.
