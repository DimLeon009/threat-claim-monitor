# Documentation

This directory contains the technical, operational, and security documentation for Threat Claim Monitor. The root README explains the product; these documents explain how and why it works.

## Recommended reading path

1. [System architecture](architecture/architecture.md)
2. [ADR-0001: Minimal V1 architecture](architecture/adr/0001-minimal-v1-architecture.md)
3. [Data model](architecture/data-model.md)
4. [Threat model](security/threat-model.md)
5. [Matching normalization](matching/normalization.md)
6. [Getting started](operations/getting-started.md)
7. Platform guide for [Windows](development/windows.md) or [macOS](development/macos.md)

## Documentation map

### Architecture

| Document | Purpose |
|---|---|
| [Architecture](architecture/architecture.md) | Components, layers, trust boundaries, networks, data flow, and failure behavior |
| [Data model](architecture/data-model.md) | Entities, relationships, invariants, retention, and migration rules |
| [ADR index](architecture/adr/README.md) | Accepted and proposed architecture decisions |
| [ADR-0001](architecture/adr/0001-minimal-v1-architecture.md) | Choice of n8n, PostgreSQL, host-native Ollama, and Compose |

### Operations

| Document | Purpose |
|---|---|
| [Getting started](operations/getting-started.md) | Configure, validate, start, and inspect the stack |
| [Health and recovery](operations/health-and-recovery.md) | Health checks, common failure modes, safe restart, and recovery boundaries |
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

### Matching

| Document | Purpose |
|---|---|
| [Normalization](matching/normalization.md) | Deterministic text, threat-actor, and approved-domain normalization contract |
| [Exact matching](matching/exact-matching.md) | Domain, official-name, approved-alias, confidence, and collision rules |
| [Claim correlation](matching/claim-correlation.md) | Transactional 45-day correlation, replay, concurrency, evidence versions, and match persistence |

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
