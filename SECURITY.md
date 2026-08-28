# 🔒 Security policy

Threat Claim Monitor processes attacker-influenced public CTI content and may hold notification credentials. Security controls are part of the product behavior, not optional deployment polish.

## Supported versions

Before the first stable release, security fixes target the current default branch. After v1.0.0, supported release lines will be listed here.

| Version | Supported |
|---|:---:|
| Default branch before v1.0.0 | ✅ |
| Historical development snapshots | ❌ |

## Reporting a vulnerability

Do not open a public issue for a vulnerability that could expose:

- credentials or encryption keys;
- webhook URLs or notification channels;
- organization watchlists;
- PostgreSQL or n8n data;
- host services;
- a reliable workflow-bypass or prompt-injection path;
- personal data.

Use GitHub private vulnerability reporting after it is enabled on the published repository. Until then, contact the repository owner privately through an agreed organizational channel.

Include:

- affected version or commit;
- operating system and deployment mode;
- impact and prerequisites;
- minimal reproduction using synthetic data;
- relevant sanitized logs;
- suggested mitigation if known.

Do not attach real stolen data, live credentials, malware, or active exploit payloads.

## Coordinated disclosure

The maintainer will aim to:

1. acknowledge a valid report;
2. reproduce and assess impact;
3. prepare a fix and regression test;
4. coordinate a disclosure date when appropriate;
5. credit the reporter unless anonymity is requested.

No guaranteed response timeline is offered during the pre-release stage, but credible reports will be prioritized.

## Security principles

### Defensive use only

The project monitors public metadata for defensive awareness. It does not need stolen datasets, malware samples, criminal credentials, or direct interaction with threat actors.

### Least exposure

- n8n binds to localhost in the reference Compose file.
- PostgreSQL has no published host port.
- only n8n receives outbound network access;
- remote access requires a separate authenticated TLS design.

### Evidence with uncertainty

Claims are stored as claims. Multi-source observation does not automatically become confirmation. Notifications must preserve the distinction.

### Deterministic control path

Probabilistic model output cannot decide matches, confidence, verification, or routing.

### Fail closed

Malformed source data, invalid model output, missing required fields, and schema changes are rejected or routed to review instead of guessed.

## Secrets management

Secrets include:

- `POSTGRES_PASSWORD`;
- `N8N_ENCRYPTION_KEY`;
- n8n owner credentials;
- API keys introduced by future sources;
- SMTP passwords;
- Teams and generic webhook URLs.

Requirements:

- never commit `.env`;
- never place real secrets in `.env.example`;
- keep the n8n encryption key stable and backed up securely;
- use n8n’s encrypted credential store for integration secrets;
- avoid credentials in workflow JSON, node names, test fixtures, screenshots, and logs;
- rotate a secret immediately if it is exposed;
- review Git history, not only the current file, after accidental commits.

## Prohibited repository data

Do not commit or attach:

- leaked databases or excerpts containing personal data;
- ransom notes obtained from a real victim environment;
- malware or weaponized exploit code unrelated to a controlled test;
- authentication tokens or session cookies;
- production logs;
- private incident reports;
- real customer or employee information;
- screenshots containing secrets or identifying victim data.

Tests and demonstrations must use synthetic, generated, or irreversibly redacted fixtures.

## Source security

All source fields are untrusted, including victim name, description, actor name, URLs, and embedded markup.

Source adapters must:

- call only configured endpoints;
- prefer HTTPS;
- enforce timeouts and bounded retries;
- validate content type and structure;
- limit response and field sizes;
- avoid automatically following extracted URLs;
- store only required public metadata;
- sanitize errors and attribution.

Direct access to criminal infrastructure is outside the V1 architecture.

## AI safety

Threat actors may deliberately publish prompt-injection text. The local model must be treated as an untrusted transformation component.

Required controls:

- source content delimited as data;
- no tools, browser, retrieval, or credentials exposed to the model;
- strict JSON Schema output;
- low-temperature deterministic configuration;
- response parsing and validation;
- unknown values represented as unknown rather than inferred;
- model, prompt version, and input hash retained;
- deterministic fallback on any failure;
- no model authority over alert decisions.

Schema-valid output may still be factually wrong. Human validation remains required before operational or public action.

## Database security

- PostgreSQL remains on the internal Compose network.
- Source-derived values use parameterized queries.
- Constraints enforce confidence ranges, states, uniqueness, and lineage.
- Database errors stored for diagnostics are sanitized.
- Backups must protect both data and the n8n encryption key.
- Destructive migrations require explicit recovery notes and validation.

## Docker and host security

- Use pinned image versions; do not commit `latest` tags.
- Keep Docker Desktop and host operating systems supported and patched.
- Do not mount the Docker socket into n8n.
- Do not run privileged containers.
- Do not publish PostgreSQL for convenience.
- Review new volume mounts for secret or host-filesystem exposure.
- Keep unverified community packages and unused Python Code-node execution disabled.
- Keep the unused n8n public API, public workflow templates, and community-package installation disabled.
- Bound Code-node execution time and Compression-node decompression size and entry count.
- Run container vulnerability scanning before v1.0.0 releases.

## Notification security

- Store channel credentials in the credential store.
- Escape source-derived content for each target format.
- Do not include raw payloads or criminal download links.
- Include a stable alert ID and uncertainty disclaimer.
- Bound response excerpts stored in attempt history.
- Use retry limits and dead-letter state to prevent uncontrolled loops.

## Logging and error handling

Logs may contain operational metadata but must not contain:

- authorization headers;
- passwords or encryption keys;
- complete webhook URLs;
- raw stolen content;
- unnecessary personal data;
- full third-party response bodies without review.

Errors persisted in PostgreSQL should be concise, sanitized, and sufficient for diagnosis.

## Dependency and image management

- Dependabot monitors GitHub Actions and Docker references.
- Version updates require configuration validation and startup smoke tests.
- Security updates may bypass normal roadmap ordering but not review and validation.
- Major n8n or PostgreSQL upgrades require migration and rollback planning.

Repository security gates and local reproduction commands are documented in the [security scanning runbook](docs/security/security-scanning.md). Gitleaks scans the complete Git history with redacted output. Trivy records all container findings and blocks every `CRITICAL` result unless an exact, reviewed, unexpired `not_affected` exception matches the current image finding.

## Security validation checklist

Before v1.0.0:

- [ ] Enable GitHub private vulnerability reporting.
- [ ] Enable repository secret scanning.
- [x] Add container vulnerability scanning.
- [x] Run the n8n security audit.
- [x] Test source response-size limits and malformed schemas.
- [x] Run prompt-injection regression tests.
- [x] Verify SQL parameterization for all source-derived values.
- [x] Test notification retry and dead-letter behavior.
- [x] Complete backup and restore exercise.
- [x] Review retention and deletion behavior.
- [x] Verify Windows and macOS network exposure.

## Threat model

Assets, adversaries, abuse cases, residual risks, and STRIDE coverage are documented in the [threat model](docs/security/threat-model.md).

The formal V1 review, findings, and release gates are recorded in the
[V1 architecture and threat-model review](docs/security/v1-architecture-threat-review.md).

## Disclaimer

This project provides defensive automation and is not a substitute for incident response, legal advice, forensic investigation, or authoritative breach confirmation. Operators are responsible for validating alerts and complying with applicable law and source terms.
