# ADR-0002: Hybrid local and Microsoft Foundry inference

- **Status:** Accepted
- **Date:** 2026-08-18

## Context

Milestone 3 established a bounded local-analysis contract with host-native Ollama. The project now also needs Microsoft Foundry for the enterprise AI path requested by project supervision.

Replacing Ollama would remove the offline and data-sovereign mode without improving the deterministic controls around matching or verification. Duplicating the complete analysis pipeline would allow the two providers to drift in prompt safety, validation, fallback, and audit behavior. Microsoft Foundry also introduces a new external trust boundary, usage cost, authentication dependency, content filtering, quota behavior, and a choice of data-processing scope.

## Decision

Keep Ollama and add Microsoft Foundry as replaceable inference providers behind the same `claim-analysis-v1` contract.

Provider selection is explicit configuration. A local failure must never trigger an automatic cloud request. This prevents a service outage from silently changing the data-processing boundary or creating unplanned cost.

Both providers receive the same bounded, allow-listed public metadata and must produce the same strict JSON shape. The same semantic validator, evidence-reference checks, uncertainty disclaimer, deterministic fallback, input hash, and database persistence boundary apply to both providers. Neither provider can set organization matches, confidence, verification state, routing, or notification eligibility.

Use the generally available OpenAI-compatible `/openai/v1` API for Foundry. The endpoint and deployment metadata are non-secret runtime configuration. Authentication material stays in the n8n credential store. Microsoft Entra ID is preferred; an API key is permitted only for a locally operated prototype when approved and stored as a credential.

Cloud requests are limited to public ransomware-claim metadata already accepted by the source contract. Leaked files, stolen content, secrets, personal records, internal investigation notes, and raw unbounded payloads are never sent. The selected Foundry deployment type, region or data zone, model version, and content-filter configuration must be reviewed and persisted as provenance before activation.

## Consequences

### Positive

- Satisfies the enterprise Foundry requirement without discarding the validated local mode.
- Preserves one prompt, schema, validation, and fallback contract.
- Makes provider comparison and controlled migration possible.
- Keeps offline demonstrations and development available when Azure is unavailable.
- Records enough deployment provenance to reproduce and audit cloud output.

### Negative

- Adds an external trust boundary, Azure configuration, quota, latency, and cost.
- Requires explicit provider routing and provider-aware persistence uniqueness.
- Model capabilities and structured-output support must be checked per deployment.
- Entra ID from a local n8n container requires more setup than a static API key.
- Data-processing scope and content filters become operational configuration that can drift.

## Rejected alternatives

- **Replace Ollama with Foundry:** removes the sovereign offline path and wastes the validated local implementation.
- **Maintain two complete analysis pipelines:** creates prompt, schema, validation, and audit drift.
- **Automatically fall back from Ollama to Foundry:** silently changes the data boundary and can generate unexpected cost.
- **Use Foundry agents:** the task is bounded structured inference and requires no tools, memory, retrieval, or autonomous behavior.
- **Use the deprecated Azure AI Inference beta SDK:** the stable OpenAI-compatible v1 API is the supported integration boundary.
