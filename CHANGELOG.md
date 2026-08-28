# Changelog

All notable changes to Threat Claim Monitor are documented in this file.

The project follows Semantic Versioning. Until the first stable tag is created,
the complete V1 release candidate remains under `Unreleased`.

## [Unreleased]

### Added

- Baseline-safe ingestion from ransomware.live, RansomLook, and FrenchBreaches
  RSS with bounded, fail-closed source contracts.
- Deterministic normalization, exact organization matching, claim correlation,
  cross-source evidence linking, and collision-safe review behavior.
- Evidence-grounded French analysis through local Ollama or Microsoft Foundry
  with exclusive provider routing, stored provenance, strict output validation,
  and deterministic fallback.
- Durable notification outbox with generic webhook, SMTP email, and Teams
  Workflows dispatchers, stable alert identifiers, bounded retries, leases, and
  dead-letter handling.
- End-to-end synthetic demonstration that exercises collection, matching,
  analysis, notification, verification, and scoped cleanup without real victim
  data.
- Verified PostgreSQL and n8n backup and restore procedure, including a macOS
  backup script and isolated Windows restoration exercise.
- Configurable evidence-preserving retention and read-only operational source
  and notification dashboards.
- Clean-install validation on Windows 11 and runtime validation on Apple Silicon.

### Security

- Localhost-only n8n exposure, internal-only PostgreSQL networking, hardened n8n
  runtime settings, and explicit cloud-inference trust boundary.
- Complete-history Gitleaks scanning and pinned Trivy container-image gates.
- Transactional failure-mode suite, prompt-injection regression cases, malformed
  source contracts, and deterministic matching corpus.
- Reviewed inventory of every PostgreSQL workflow node with automated rejection
  of unparameterized source-derived SQL and migration-time dynamic SQL.
- Formal V1 architecture and threat-model review with documented residual risks
  and deployment gates.

### Operations

- Cross-platform repository validation for Windows and macOS/Linux.
- Immutable PostgreSQL migration history through migration 026.
- Documented source switches, analysis-provider selection, notification-channel
  activation, recovery, retention, health inspection, and release procedure.
- Beginner installation and workflow-deployment paths with explicit fresh-n8n,
  credential, sub-workflow, baseline, and troubleshooting behavior.
- Support routing for help, bugs, features, implementation tasks, pull requests,
  and private vulnerability reports.
- Remote single-administrator guidance that preserves localhost exposure through
  SSH or VPN and treats public HTTPS hosting as a separate deployment review.

The release commit will replace `Unreleased` with `1.0.0` and its release date.
