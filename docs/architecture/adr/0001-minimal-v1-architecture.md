# ADR-0001: Minimal V1 architecture

- **Status:** Accepted
- **Date:** 2026-08-14

## Context

Threat Claim Monitor must be self-hosted, work on Windows and Apple Silicon, remain understandable to a single developer, and provide durable deduplication and history. It also needs visual workflow automation and local AI without making the model a source of truth.

## Decision

Use n8n as the workflow orchestrator, PostgreSQL as both the n8n backend and application datastore, and Ollama as a host-native local inference service. Run n8n and PostgreSQL with Docker Compose. Keep the n8n and application data in separate PostgreSQL databases on one server.

The initial structured sources are ransomware.live and RansomLook. FrenchBreaches uses a minimal RSS metadata adapter, remains disabled by default on clean installations, and can be enabled after its local runtime contract is reviewed.

Ollama will summarize normalized evidence with a JSON Schema. Matching, confidence, correlation, verification status, and notification routing remain deterministic.

## Consequences

### Positive

- Small operational footprint and simple installation.
- Durable SQL constraints support idempotency and auditability.
- Workflows can be exported and reviewed in Git.
- Native Ollama can use host acceleration on macOS and Windows.
- Source adapters and notification channels can be added independently.

### Negative

- n8n workflow exports are JSON and require disciplined review.
- One PostgreSQL instance is a shared dependency, although databases are separated.
- Native Ollama is one installation step outside Compose.
- Exactly-once delivery cannot be guaranteed for every external channel; the outbox minimizes duplicates and preserves attempts.

## Rejected alternatives

- **SQLite:** insufficient concurrency and operational visibility for durable correlation and outbox processing.
- **Custom application first:** would delay the working V1 and reduce the intended n8n learning value.
- **Kubernetes:** disproportionate operational cost for a single-host V1.
- **Qdrant/RAG:** no current retrieval problem justifies a vector database.
- **LLM-based matching:** difficult to reproduce and unsafe for alert routing.
