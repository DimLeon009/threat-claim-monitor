# Documentation

This directory contains the technical, operational, and security documentation for Threat Claim Monitor. The root README explains the product; these documents explain how and why it works.

## Recommended reading path

1. [System architecture](architecture/architecture.md)
2. [ADR-0001: Minimal V1 architecture](architecture/adr/0001-minimal-v1-architecture.md)
3. [ADR-0002: Hybrid local and Microsoft Foundry inference](architecture/adr/0002-hybrid-local-foundry-inference.md)
4. [Data model](architecture/data-model.md)
5. [Threat model](security/threat-model.md)
6. [Matching normalization](matching/normalization.md)
7. [Notification contract](notifications/notification-contract.md)
8. [Getting started](operations/getting-started.md)
9. Platform guide for [Windows](development/windows.md) or [macOS](development/macos.md)

## Documentation map

### Architecture

| Document | Purpose |
|---|---|
| [Architecture](architecture/architecture.md) | Components, layers, trust boundaries, networks, data flow, and failure behavior |
| [Data model](architecture/data-model.md) | Entities, relationships, invariants, retention, and migration rules |
| [ADR index](architecture/adr/README.md) | Accepted and proposed architecture decisions |
| [ADR-0001](architecture/adr/0001-minimal-v1-architecture.md) | Choice of n8n, PostgreSQL, host-native Ollama, and Compose |
| [ADR-0002](architecture/adr/0002-hybrid-local-foundry-inference.md) | Explicit provider routing, Foundry trust boundary, data policy, and shared analysis contract |

### Operations

| Document | Purpose |
|---|---|
| [Getting started](operations/getting-started.md) | Configure, validate, start, and inspect the stack |
| [Health and recovery](operations/health-and-recovery.md) | Health checks, common failure modes, safe restart, and recovery boundaries |
| [End-to-end synthetic demo](operations/end-to-end-synthetic-demo.md) | Safe M6 collection-to-webhook scenario, verification, and scoped cleanup |
| [Backup and restore](operations/backup-and-restore.md) | Dual-database backup, n8n volume preservation, isolated restore, and verification |
| [Failure-mode validation](operations/failure-mode-validation.md) | Transactionally isolated correlation, source-health, inference, retry, and dead-letter tests |
| [Infrastructure](../infra/README.md) | Compose topology, volumes, networking, and image policy |

### Development

| Document | Purpose |
|---|---|
| [Windows](development/windows.md) | Docker Desktop, PowerShell, native Ollama, and local validation |
| [macOS](development/macos.md) | Apple Silicon, Docker Desktop, native Ollama, and host networking |
| [Contributing](../CONTRIBUTING.md) | Branches, commits, migrations, workflows, tests, and review expectations |

### Sources

| Document | Purpose |
|---|---|
| [ransomware.live](sources/ransomware-live.md) | Public API contract, stable identity, silent baseline, and fixture policy |
| [RansomLook](sources/ransomlook.md) | Secondary API contract, response-wrapper compatibility, and silent baseline |
| [FrenchBreaches](sources/frenchbreaches.md) | Minimal RSS allow-list, permission boundary, cache-aware polling, and silent baseline |

### Matching

| Document | Purpose |
|---|---|
| [Normalization](matching/normalization.md) | Deterministic text, threat-actor, and approved-domain normalization contract |
| [Exact matching](matching/exact-matching.md) | Domain, official-name, approved-alias, confidence, and collision rules |
| [Claim correlation](matching/claim-correlation.md) | Transactional 45-day correlation, replay, concurrency, evidence versions, and match persistence |
| [Cross-source correlation](matching/cross-source-correlation.md) | Multi-source transition, replay safety, and lifetime new-claim deduplication |
| [Threat-actor aliases](matching/threat-actor-aliases.md) | Approved canonical actor names, exact aliases, disabled mappings, and fail-closed collisions |
| [Review candidates](matching/review-candidates.md) | Token and fuzzy candidate rules, bounded scores, evidence, and anti-auto-alert invariants |

### Local AI

| Document | Purpose |
|---|---|
| [Local analysis contract](ai/local-analysis-contract.md) | Pinned Ollama profiles, untrusted-input boundary, strict JSON output, validation, and fallback |
| [Inference provider contract](ai/inference-providers.md) | Shared Ollama/Foundry contract, cloud selection, authentication, provenance, and data boundary |

### Notifications

| Document | Purpose |
|---|---|
| [Notification contract](notifications/notification-contract.md) | Common payload, eligibility, transactional outbox, idempotency, concurrency, and credential boundary |
| [Generic webhook](notifications/generic-webhook.md) | WF-60 import, credential boundary, delivery behavior, failure handling, and runtime validation |
| [SMTP email](notifications/smtp-email.md) | WF-61 safe rendering, SMTP credential boundary, import, delivery behavior, and validation |
| [Teams Workflows](notifications/teams-workflows.md) | WF-62 Adaptive Card, webhook ownership, signature credential, safe rendering, and smoke test |

### Security

| Document | Purpose |
|---|---|
| [Security policy](../SECURITY.md) | Disclosure process and repository security requirements |
| [Threat model](security/threat-model.md) | Assets, adversaries, boundaries, abuse cases, and controls |

## Documentation conventions

- Architecture decisions use ADRs and are not silently reversed.
- Commands must identify their intended platform.
- Examples must use synthetic or redacted data.
- Planned behavior must be labeled as planned.
- Links are relative so documentation remains usable from forks.
- Material behavior changes require documentation in the same pull request.
