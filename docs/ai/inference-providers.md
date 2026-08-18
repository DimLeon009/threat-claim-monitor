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

The endpoint hostname must end in `.openai.azure.com` or `.services.ai.azure.com`. Requests use `/openai/v1/chat/completions`. Microsoft Entra ID is preferred. If an API key is approved for the local prototype, it belongs only in an n8n credential and must never appear in workflow JSON, execution data, PostgreSQL, screenshots, or Git.

## Data policy

Only the already bounded public metadata analysis input may be transmitted. Do not send leaked files, stolen data, secrets, personal records, raw source payloads, or internal investigation notes.

Global, data-zone, and regional deployments have different processing-location properties. The selected scope must be approved before the provider is enabled and stored with every analysis result.

## Failure behavior

Authentication failure, quota exhaustion, rate limiting, content filtering, timeout, invalid output, or provider unavailability produces a sanitized allow-listed failure and the same deterministic fallback. Raw provider responses and authentication details are not persisted.

The local provider remains independently runnable. Cloud use is never an implicit recovery action.
