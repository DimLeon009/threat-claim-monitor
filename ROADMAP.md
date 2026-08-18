# 🗺️ Threat Claim Monitor roadmap

## Roadmap principles

The roadmap is milestone-based rather than feature-count based. A milestone is complete only when its observable acceptance criteria pass and its documentation matches the implementation.

Priorities are:

1. reliable collection;
2. low false-positive matching;
3. safe retries and evidence lineage;
4. useful analyst notifications;
5. operational quality;
6. optional platform expansion.

Dates are assigned through GitHub milestones and issues after the preceding dependency is stable.

## Status legend

| Symbol | Meaning |
|:---:|---|
| ✅ | Implemented and validated |
| 🚧 | In progress or partially validated |
| ⏳ | Planned next |
| 🧭 | Future candidate requiring validation |
| ❌ | Explicitly outside the current scope |

## Milestone overview

| Milestone | Outcome | Status |
|---|---|:---:|
| M0 | Reproducible professional foundation | ✅ |
| M1 | First reliable ransomware claim feed | ✅ |
| M2 | Deterministic watchlist matching and correlation | ✅ |
| M3 | Evidence-grounded local summaries | ⏳ |
| M4 | Auditable multi-channel notifications | Planned |
| M5 | Resilient multi-source coverage | Planned |
| M6 | Hardened v1.0.0 portfolio release | Planned |

## ✅ M0 — Foundation

### Objective

Provide a clean repository and reproducible runtime on which every later workflow can be implemented without restructuring the project.

### Deliverables

- [x] Git repository initialized on `main`
- [x] Docker Compose definition for n8n and PostgreSQL
- [x] Host-native Ollama integration contract
- [x] Separate n8n and application databases
- [x] Initial schema with evidence, matching, analysis, and outbox entities
- [x] Seed sources, organizations, domains, and aliases
- [x] Environment template and ignored local secrets
- [x] Cross-platform validation scripts
- [x] GitHub Actions validation
- [x] Dependabot configuration
- [x] Issue and pull-request templates
- [x] Architecture, data model, threat model, and ADR documentation
- [x] Windows and macOS development guides
- [x] Docker Desktop runtime smoke test
- [x] Confirm first-start database initialization

### Acceptance criteria

- `docker compose config` passes with configured secrets.
- PostgreSQL becomes healthy.
- n8n starts and is reachable only on localhost.
- Both databases exist.
- `schema_migrations` contains `001_initial_schema`.
- Three organizations and three sources are seeded.
- Restarting without volume deletion preserves state.
- Documentation links and repository validation pass.

### Exit artifact

A new contributor can clone, configure, start, inspect, stop, and restart the foundation using documented commands.

## ✅ M1 — ransomware.live collection

### Objective

Collect recent ransomware.live records safely and insert each source observation exactly once without generating historical alert noise.

### Deliverables

- [x] `WF-00 Orchestrator`
- [x] `WF-10 Collect ransomware.live`
- [x] HTTP timeout and bounded retry policy
- [x] Content-type and response-shape validation
- [x] Common normalized observation contract
- [x] Stable source-key generation
- [x] Collection run history and sanitized failures
- [x] Silent first-run baseline
- [x] Redacted source contract fixture
- [x] Duplicate replay test
- [x] Malformed response and timeout tests
- [x] Workflow export documentation

### Acceptance criteria

- A new API record creates one observation.
- Replaying the same response creates no additional observation.
- First-run historical observations have `is_historical = true`.
- Historical observations cannot enter the notification path.
- A source failure does not corrupt partial state.
- Logs and persisted errors contain no credentials or excessive payloads.

## ✅ M2 — Matching and claim correlation

### Objective

Identify monitored organizations with explainable rules and correlate source duplicates without hiding uncertainty.

### Deliverables

- [x] Unicode and punctuation normalization contract
- [x] Registered-domain extraction and normalization
- [x] Threat-actor alias normalization
- [x] Canonical claim creation
- [x] 45-day correlation window
- [x] Exact domain, official-name, and alias matching
- [x] Review path for token and fuzzy candidates
- [x] Match evidence payload
- [x] Evidence-version updates
- [x] Positive, negative, ambiguous, and collision corpus
- [x] Concurrency and replay tests
- [x] Collection-workflow correlation integration

### Acceptance criteria

- Domain exact matches score 100.
- Official-name exact matches score 95.
- Only approved aliases can auto-alert.
- Fuzzy similarity never auto-alerts.
- The validation corpus produces no false automatic alert.
- One observation links to at most one canonical claim.
- Correlation decisions remain explainable from stored evidence.

## ⏳ M3 — Local AI analysis

### Objective

Produce concise French analyst summaries from normalized evidence without allowing the model to invent control-plane decisions.

### Deliverables

- [ ] Host-native Ollama connectivity check
- [ ] Pinned `qwen3:8b-q4_K_M` model and recorded digest
- [ ] Qwen3 4B explicit fallback profile
- [ ] Versioned system and extraction prompt
- [ ] Strict JSON Schema
- [ ] Temperature-zero, non-agent inference
- [ ] Input truncation and untrusted-content delimiters
- [ ] Schema and semantic validation
- [ ] Deterministic non-AI fallback summary
- [ ] Prompt-injection regression corpus
- [ ] Unsupported-fact and missing-value tests
- [ ] Analysis provenance storage

### Acceptance criteria

- Invalid model output never blocks claim processing.
- Unknown source facts remain unknown.
- Model output cannot set match confidence or verification state.
- Each stored analysis identifies model, prompt version, and input hash.
- The same fixture produces structurally stable output.
- A malicious source instruction cannot trigger tools or external actions.

## M4 — Notifications

### Objective

Deliver one useful alert per material evidence version and retain complete delivery state.

### Deliverables

- [ ] Common notification contract
- [ ] Required uncertainty disclaimer
- [ ] Transactional outbox producer
- [ ] Concurrent-safe outbox claim operation
- [ ] Generic webhook adapter
- [ ] SMTP email adapter
- [ ] Microsoft Teams Workflows Adaptive Card adapter
- [ ] Bounded exponential retry
- [ ] Dead-letter state and manual requeue procedure
- [ ] Attempt history and response sanitization
- [ ] Channel-specific escaping tests
- [ ] Duplicate prevention tests

### Acceptance criteria

- One claim evidence version produces one logical alert per configured channel.
- A failed channel does not block other channels.
- Retry never creates a second outbox job.
- Dead-letter records remain inspectable.
- Notification content includes alert ID, organization, actor, dates, match method, confidence, verification state, sources, summary, and disclaimer.
- No raw payload, secret, or criminal download link is forwarded.

## M5 — Multi-source coverage

### Objective

Increase coverage and source resilience while preserving a single internal observation contract.

### Deliverables

- [ ] RansomLook adapter and contract fixture
- [ ] Response-wrapper compatibility test
- [ ] Cross-source claim correlation
- [ ] `multi_source_observed` transition
- [ ] FrenchBreaches RSS endpoint and automation validation
- [ ] FrenchBreaches adapter only if structured access is reliable and permitted
- [ ] Per-source health indicators
- [ ] Source enable/disable runbook
- [ ] Schema-change failure tests

### Acceptance criteria

- One source outage does not stop another source.
- Cross-source publication does not produce a duplicate new-claim alert.
- Multi-source observation is never labeled official confirmation.
- An incompatible source schema fails closed.
- Experimental sources can be disabled without workflow edits.

## M6 — Hardening and v1.0.0

### Objective

Release a demonstrable, recoverable, and professionally documented V1 suitable for internal use and portfolio presentation.

### Deliverables

- [ ] End-to-end synthetic demonstration scenario
- [ ] Windows 11 installation validation
- [ ] Apple Silicon installation validation
- [ ] Backup and restore scripts and exercise
- [ ] n8n security audit
- [ ] Secret scanning
- [ ] Container vulnerability scanning
- [ ] Failure-mode test suite
- [ ] Configurable retention job
- [ ] Source and channel operational dashboards in n8n or SQL views
- [ ] Architecture and threat-model review
- [ ] Release checklist, changelog, and tagged `v1.0.0`
- [ ] Portfolio screenshots and concise demonstration guide

### Acceptance criteria

- A clean installation reaches a verified alert from a synthetic source fixture.
- Backup restoration preserves configuration, claims, and notification history.
- No critical known vulnerability remains without documented mitigation.
- All V1 workflows are exported, sanitized, and version controlled.
- Documentation matches actual Windows and macOS behavior.
- The project can be demonstrated without real victim data or live-channel risk.

## 🧭 Post-V1 candidates

Candidates are not commitments. Each requires a concrete use case and, where appropriate, an ADR.

### Confirmation and enrichment

- CERT-FR publications
- Have I Been Pwned breach records
- official organization statements
- analyst confirmation workflow
- source reliability history

### Analyst experience

- read-only dashboard
- claim search and filters
- review queue
- statistics and trend reports
- PDF or Markdown reporting

### Broader CTI

- CISA KEV and CVE monitoring
- IOC management
- MISP integration
- vendor advisories
- security RSS monitoring

### Platform integrations

- Slack and Discord
- Azure DevOps work items
- incident-management platforms
- authenticated REST API

### Semantic capabilities

- Qdrant
- embeddings
- RAG over internal and public defensive documentation

Qdrant and RAG will be considered only when semantic retrieval provides measurable value that relational search and deterministic enrichment cannot provide.

## Explicitly out of scope for V1

- direct interaction with threat actors;
- downloading or redistributing leaked data;
- automated incident confirmation;
- public Internet exposure without an authenticated proxy;
- autonomous remediation;
- Kubernetes;
- high-availability clustering;
- a general-purpose threat intelligence platform.

## Definition of done

A roadmap item is done when:

- implementation is complete;
- relevant automated and manual tests pass;
- failure behavior is tested;
- security implications are reviewed;
- documentation is updated;
- workflow exports are sanitized;
- acceptance evidence is recorded in the pull request.
