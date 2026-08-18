# Inference provider contract

## Purpose

Threat Claim Monitor supports two inference providers without giving either provider control over deterministic application decisions:

| Provider | Role | Data boundary |
|---|---|---|
| Ollama | Sovereign local mode and offline fallback capability | Windows or macOS host |
| Microsoft Foundry | Enterprise cloud inference mode | Explicitly selected Azure deployment |

Provider selection is configuration, not model output. An Ollama error never causes an automatic Foundry request.

## Shared contract

Both providers use:

- prompt version `claim-analysis-v1`;
- the same bounded claim and evidence payload;
- the same strict JSON Schema;
- temperature zero and no tools;
- the same semantic and evidence-reference validation;
- the same deterministic fallback;
- the same input hashing and idempotent persistence boundary.

Provider adapters may translate request and response envelopes, but they must not change the meaning or limits of the shared contract.

Microsoft Foundry structured outputs support only a subset of JSON Schema. Immediately before the HTTPS request, `WF-41` removes unsupported transport keywords such as string-length, pattern, array-length, and uniqueness constraints, and converts exact `const` strings to typed single-value enums. It preserves required fields, types, enums, and `additionalProperties: false`. The full local semantic validator still enforces every original length, uniqueness, forbidden-content, and evidence-reference rule after inference, so this transport adaptation does not relax persisted output.

Migration `011_provider_aware_analysis` extends provenance and idempotency with `provider`, `deployment_name`, and bounded `provider_metadata`. The legacy two-argument analysis queue remains an Ollama-compatible wrapper. A provider-aware queue isolates work by provider and deployment, so storing an Ollama result cannot consume the corresponding Foundry job.

## Microsoft Foundry configuration

The repository profile is `ai/providers/microsoft-foundry.json`. It contains no tenant, subscription, resource, endpoint, deployment, or credential value.

Before enabling Foundry, record and review:

- the HTTPS resource endpoint;
- deployment name, model name, and model version;
- regional, data-zone, or global processing scope;
- deployment type and quota;
- content-filter configuration;
- approved authentication method;
- expected token and spending limits.

Migration `012_foundry_provider_configuration` seeds the Foundry provider disabled. Its configuration table contains only non-secret deployment metadata and accepts only HTTPS resource hosts ending in `.openai.azure.com` or `.services.ai.azure.com`, without paths. `WF-41 Microsoft Foundry analysis` loads no jobs until this row is complete and explicitly enabled.

The endpoint hostname must end in `.openai.azure.com` or `.services.ai.azure.com`. Requests use `/openai/v1/chat/completions`. Microsoft Entra ID is preferred. If an API key is approved for the local prototype, it belongs only in an n8n credential and must never appear in workflow JSON, execution data, PostgreSQL, screenshots, or Git.

For the local API-key prototype, create an n8n HTTP Header Auth credential named `Microsoft Foundry API key`, with header name `api-key` and the approved key as its value. Assign it only to the `Call Microsoft Foundry` node after importing the sanitized workflow export. Never pin request or response data on that node.

Configure the non-secret row with values copied from the approved Foundry deployment, then enable it in the same reviewed update:

```sql
UPDATE analysis_provider_configs
SET
  endpoint_base_url = 'https://RESOURCE.services.ai.azure.com',
  deployment_name = 'APPROVED_DEPLOYMENT',
  model_name = 'APPROVED_MODEL',
  model_version = 'APPROVED_VERSION',
  api_family = 'openai-v1',
  deployment_type = 'APPROVED_TYPE',
  data_processing_scope = 'APPROVED_SCOPE',
  content_filter_name = 'APPROVED_FILTER',
  enabled = true,
  updated_at = now()
WHERE provider = 'microsoft_foundry';
```

The placeholders are documentation values and must be replaced locally. No authentication value belongs in this statement.

## Data policy

Only the already bounded public metadata analysis input may be transmitted. Do not send leaked files, stolen data, secrets, personal records, raw source payloads, or internal investigation notes.

Global, data-zone, and regional deployments have different processing-location properties. The selected scope must be approved before the provider is enabled and stored with every analysis result.

## Failure behavior

Authentication failure, quota exhaustion, rate limiting, content filtering, timeout, invalid output, or provider unavailability produces a sanitized allow-listed failure and the same deterministic fallback. WF-41 recognizes both direct HTTP status fields and n8n's nested `error.status` shape. Repository-safe synthetic cases cover 401, 403, 429, content-filter rejection, timeout, and provider unavailability. Raw provider responses and authentication details are not persisted.

The local provider remains independently runnable. Cloud use is never an implicit recovery action.

## Workflow validation

Run the offline workflow contract without a Foundry subscription or credential:

```sh
python3 scripts/test_foundry_workflow_contract.py
```

With PostgreSQL running, validate the disabled-by-default configuration, endpoint allow-list, lookalike rejection, and absence of secret-bearing columns:

```sh
docker compose exec -T postgres psql -U tcm_admin -d threat_claim_monitor -f /dev/stdin < scripts/test_foundry_provider_configuration.sql
```
