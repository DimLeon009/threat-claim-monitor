# 🤝 Contributing to Threat Claim Monitor

Thank you for helping improve Threat Claim Monitor. Contributions should preserve the project’s defensive purpose, evidence lineage, deterministic decision path, and deliberately small V1 architecture.

## Before contributing

Read:

1. [Architecture](docs/architecture/architecture.md)
2. [Data model](docs/architecture/data-model.md)
3. [Security policy](SECURITY.md)
4. [Threat model](docs/security/threat-model.md)
5. [Roadmap](ROADMAP.md)

Search existing issues before opening a new one. Security vulnerabilities must follow the private reporting process in `SECURITY.md` and must not be disclosed in a public issue.

Use [SUPPORT.md](SUPPORT.md) to choose between installation help, a bug report,
a feature request, an implementation task, a pull request, and a private
vulnerability report.

## Development principles

- One issue and one observable outcome per pull request.
- Prefer a working, testable V1 improvement over speculative infrastructure.
- Preserve original source evidence before deriving conclusions.
- Keep alert decisions deterministic and reproducible.
- Treat all source and model content as untrusted.
- Use only synthetic or redacted test data.
- Document behavior and architecture changes in the same pull request.

## Branch workflow

Create a branch from the current default branch.

| Change | Pattern | Example |
|---|---|---|
| Feature | `feat/<short-description>` | `feat/ransomware-live-adapter` |
| Bug fix | `fix/<short-description>` | `fix/baseline-notification-guard` |
| Documentation | `docs/<short-description>` | `docs/source-contract` |
| Refactor | `refactor/<short-description>` | `refactor/normalization-step` |
| Security | `security/<short-description>` | `security/redact-webhook-errors` |
| Maintenance | `chore/<short-description>` | `chore/update-n8n` |

Keep names lowercase, concise, and hyphenated.

## Commit convention

Conventional Commit prefixes are encouraged:

```text
feat: add ransomware.live observation mapping
fix: prevent baseline records from entering the outbox
docs: document source adapter contract
test: add ambiguous organization fixtures
refactor: isolate victim name normalization
security: redact authorization headers from errors
chore: update pinned postgres patch version
```

A commit should explain one coherent change. Avoid messages such as `update`, `changes`, or `fix stuff`.

Breaking changes must be explicit:

```text
feat!: change normalized observation contract
```

## Repository structure

```text
.
├── .github/                 CI and collaboration templates
├── db/migrations/           Ordered PostgreSQL schema changes
├── docs/architecture/       Architecture, data model, and ADRs
├── docs/development/        Platform-specific development guides
├── docs/operations/         Installation and recovery runbooks
├── docs/security/           Threat model
├── infra/postgres/init/     Fresh-volume initialization
├── n8n/workflows/           Sanitized workflow exports
└── scripts/                 Cross-platform validation
```

Do not create new top-level directories without a clear ownership and documentation reason.

## Local setup

Follow the [getting-started guide](docs/operations/getting-started.md) and the guide for [Windows](docs/development/windows.md) or [macOS](docs/development/macos.md).

Run validation before and after a change.

Windows:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/validate.ps1
```

macOS or Linux:

```sh
sh scripts/validate.sh
```

## n8n workflow guidelines

### Naming

Use stable ordered names:

```text
WF-00 Orchestrator
WF-10 Collect ransomware.live
WF-40 Local analysis
WF-60 Dispatch generic webhook
WF-70 Configurable retention
```

Node names should describe outcomes, for example `Insert observation if new`, not `Postgres 3`.

### Structure

- Keep source adapters separate from domain processing.
- Use sub-workflows for reusable normalization, analysis, and delivery logic.
- Keep credential selection outside committed workflow data where possible.
- Configure timeouts and bounded retries for network calls.
- Route failures to explicit error handling.
- Write application state to PostgreSQL, not static workflow data.
- Avoid large Code nodes when smaller explicit nodes remain readable.

### Export hygiene

Before committing an export:

- remove credentials and tokens;
- inspect webhook URLs and headers;
- remove pinned sample data containing real entities other than the approved watchlist;
- ensure workflow names and filenames are stable;
- review the JSON diff for unrelated editor churn;
- add or update its documentation and test fixture.

Recommended filename format:

```text
wf-10-collect-ransomware-live.json
```

## Source adapter contract

Every adapter must:

1. use a documented structured endpoint;
2. define timeout and retry behavior;
3. validate content type and response shape;
4. map into the common observation fields;
5. generate a stable source key;
6. preserve a minimal sanitized raw payload;
7. record a collection run;
8. include redacted or synthetic contract fixtures;
9. fail closed if required fields disappear;
10. document usage constraints and attribution.

Do not add HTML scraping when a supported API, RSS, or JSON feed exists.

## Database migrations

- Name migrations `NNN_snake_case.sql`.
- Never edit a migration that may already have been applied.
- Wrap changes in a transaction when PostgreSQL supports it.
- Insert the migration version into `schema_migrations`.
- Prefer constraints that make retries and concurrency safe.
- Add indexes only for a demonstrated access pattern.
- Do not store secrets or environment-specific endpoints in seeds.
- Include backup and rollback notes for destructive changes.

New state transitions require documentation in the data model and tests for invalid transitions.

## AI safety requirements

Language models may summarize and extract fields, but they must not determine:

- organization identity;
- match confidence;
- verification status;
- notification routing;
- whether an incident is confirmed;
- destructive or externally visible actions.

AI-related changes require:

- a versioned prompt;
- a strict output schema;
- temperature and inference options documented;
- invalid-output handling;
- deterministic fallback behavior;
- prompt-injection and unsupported-fact fixtures;
- model and input provenance in stored analyses.

## Testing expectations

The required depth depends on the change.

| Change | Minimum validation |
|---|---|
| Documentation | Local-link and repository validation |
| Compose or environment | `docker compose config` plus startup smoke test |
| Migration | Apply to empty DB, re-run if intended idempotent, inspect constraints |
| Source adapter | Contract fixture, duplicate replay, malformed response, timeout |
| Matching | Positive, negative, alias, ambiguous, Unicode, and collision cases |
| AI analysis | Valid schema, hallucination probe, injection probe, fallback |
| Notification | Success, timeout, retry, dead-letter, duplicate prevention |

Tests must never make destructive calls to real notification channels by default.

Documentation links and whitespace can be checked independently with:

```sh
python scripts/validate_docs.py
```

## Documentation requirements

Update documentation when a pull request changes:

- architecture or trust boundaries;
- configuration or environment variables;
- database entities or state values;
- source or notification contracts;
- installation or recovery procedures;
- security controls or data classification;
- milestone acceptance criteria.

Write an ADR for difficult-to-reverse architecture choices. Routine implementation details belong in code, workflow annotations, or normal technical documentation.

## Pull requests

A pull request should include:

- the problem and motivation;
- the chosen approach and important tradeoffs;
- a focused list of changes;
- exact validation evidence;
- risk and rollback notes when applicable;
- the related issue;
- screenshots only when they materially clarify n8n workflow or notification behavior.

Review checklist:

- [ ] Scope matches the linked issue.
- [ ] CI and relevant local tests pass.
- [ ] Retries remain safe.
- [ ] No secret or prohibited data is included.
- [ ] Source and model data remain untrusted.
- [ ] Documentation reflects behavior.
- [ ] No unapproved infrastructure complexity was introduced.
- [ ] Logs and errors are sanitized.

## Code review priorities

Reviewers should prioritize:

1. false-positive or missed-alert risk;
2. evidence lineage and uncertainty;
3. secret and personal-data exposure;
4. idempotency and failure behavior;
5. cross-platform impact;
6. maintainability and clarity;
7. style.

## Code of conduct

Participation is governed by the [Code of Conduct](.github/CODE_OF_CONDUCT.md).
