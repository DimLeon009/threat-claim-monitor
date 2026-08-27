# Security scanning

Threat Claim Monitor applies two independent repository gates: complete-history secret detection with Gitleaks and vulnerability scanning of the exact PostgreSQL and n8n container images with Trivy. The checks run on pull requests, pushes to `main`, and explicit manual dispatches.

## Pinned scanners

- Gitleaks `v8.30.1` is pinned to its official GHCR digest. The apparent default-rule regression reported upstream was traced to an intentionally allow-listed placeholder stopword and the [issue was closed](https://github.com/gitleaks/gitleaks/issues/2170).
- Trivy `v0.74.0` is pinned to its official GHCR digest. The [official release announcement](https://github.com/aquasecurity/trivy/discussions/11096) documents that release.
- GitHub Actions dependencies are pinned to full commit identifiers and remain monitored by Dependabot.

Scanner upgrades require a dedicated pull request, synthetic positive and negative validation, and a review of upstream release notes. Never replace a pin with `latest`, `master`, or an unreviewed floating tag.

## Secret-history gate

Gitleaks scans the complete Git history rather than only the current checkout. CI uses `fetch-depth: 0`, passes `--log-opts=--all`, and forces complete redaction in logs. Any finding fails the job.

Run the same scan on Windows:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/security/scan-secrets.ps1
```

Run it on macOS or Linux:

```sh
sh scripts/security/scan-secrets.sh
```

If a finding occurs:

1. do not paste the finding, report, or candidate secret into an issue, chat, or CI comment;
2. determine privately whether the value is a real credential;
3. revoke and rotate a confirmed credential before changing Git;
4. remove it from the current tree;
5. coordinate any required history rewrite because rewriting shared history is disruptive;
6. rerun the complete-history scan;
7. document only the sanitized incident outcome.

False-positive exceptions must be fingerprint-specific, reviewed, and justified. Path-wide or rule-wide exclusions are prohibited because they can conceal later leaks.

## Container vulnerability gate

Trivy scans the exact images configured by Compose:

- `postgres:17.10-alpine3.23`;
- `docker.n8n.io/n8nio/n8n:2.36.7`.

The JSON report contains all severities. The evaluator prints bounded counts and fails when at least one unreviewed `CRITICAL` finding exists. `HIGH` findings remain visible for review but do not yet block this pre-release gate. The short-lived, digest-pinned Trivy container receives the Docker engine socket only while scanning so it can inspect already-downloaded images; application containers never receive that socket.

CI pulls each reviewed image index by digest before invoking Trivy, so the scanner never falls back to an implicit remote lookup. The n8n release is pulled from the project's official `ghcr.io/n8n-io/n8n` package and locally tagged with the `docker.n8n.io/n8nio/n8n` Compose name. Both official registry references resolve to the same reviewed multi-architecture digest. This avoids registry rate-limit fallback without changing the scanned artifact or the exception identity.

Run the scans on Windows:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/security/scan-containers.ps1
```

Run them on macOS or Linux:

```sh
sh scripts/security/scan-containers.sh
```

Local JSON reports and the reusable Trivy vulnerability-database cache are written under `security-reports/`, which Git ignores. Reusing the cache avoids downloading the database separately for every image while Trivy still applies its normal freshness checks. CI retains each report as a repository-access-controlled artifact for 14 days. Reports contain package and vulnerability metadata, not application secrets, but should still not be published without review.

## Vulnerability review

For every `CRITICAL` finding:

1. verify the affected image digest and installed package version;
2. confirm applicability using the upstream advisory and package maintainer data;
3. upgrade the pinned image when a compatible fix exists;
4. rerun repository, startup, migration, and end-to-end smoke tests;
5. keep the security gate failing until the finding is removed or an exact, reviewed `not_affected` decision is recorded.

If no compatible fixed image exists, do not silently ignore the result. An exception is permitted only when applicability has been reviewed and the affected execution path is demonstrably unreachable. `security/trivy-exceptions.json` binds the decision to the exact image name, vulnerability, target binary, package, and installed version. It also requires an owner, rationale, references, and expiry date. Missing, expired, stale, broader, or unmatched exceptions fail closed.

The current PostgreSQL image contains `gosu` built with Go `1.24.6`, which Trivy associates with `CVE-2025-68121`. The official [Go advisory](https://pkg.go.dev/vuln/GO-2026-4337) affects TLS session resumption. The official [gosu security guidance](https://github.com/tianon/gosu/blob/master/SECURITY.md) requires call-graph applicability rather than treating every compiled standard-library symbol as reachable. `gosu` performs local identity resolution, credential switching, and process execution; it does not exercise the affected TLS path. The exact `not_affected` exception expires on 20 November 2026 and must be removed earlier when the pinned PostgreSQL image no longer contains the finding.

### Validation evidence — 27 August 2026

The local release-gate reproduction completed with the pinned scanners and images:

- Gitleaks `v8.30.1` scanned all 25 Git commits and reported no leaks;
- Trivy `v0.74.0` scanned `postgres:17.10-alpine3.23` and reported 1 `UNKNOWN`, 14 `LOW`, 27 `MEDIUM`, 23 `HIGH`, and 1 `CRITICAL` finding;
- the PostgreSQL `CRITICAL` finding was the exact reviewed `CVE-2025-68121` `gosu` exception described above, so no unreviewed critical finding remained;
- Trivy scanned `docker.n8n.io/n8nio/n8n:2.36.7` at image digest `sha256:14c4285bc3034dc5b51034aea393711d27053588e460722bce523453a626f23c` and reported 12 `LOW`, 12 `MEDIUM`, 3 `HIGH`, and no `UNKNOWN` or `CRITICAL` finding;
- both container gates passed and their local JSON reports remained under the ignored `security-reports/` directory.

These counts are time-bound evidence, not a permanent allow-list. A later advisory-database update may change them and must be evaluated afresh.

## Boundaries

- The workflow has read-only repository permission.
- Scanners do not receive n8n, PostgreSQL, Foundry, SMTP, Teams, or webhook credentials.
- Vulnerability reports and secret findings are never committed.
- Secret scanning complements, but does not replace, GitHub-hosted secret scanning and push protection when those repository features are available.
- Container results are time-dependent because advisory databases change; release evidence must record the scan date and scanner version.

## n8n runtime audit

Run the native audit after an n8n upgrade, a workflow import, or a credential change:

```powershell
docker compose exec -T n8n n8n audit
```

Review the report rather than treating every listed node as an exploitable defect:

- PostgreSQL nodes with dynamic input must use positional placeholders and the node's separate Query Parameters field. Constant queries without dynamic input do not require parameters.
- Code and HTTP Request nodes are expected in the collectors, inference providers, and notification dispatchers. Their scripts, destination constraints, input allow-lists, output schemas, timeouts, and sanitized failure paths remain part of security review.
- Unused credentials should be deleted. A credential retained for an intentionally dormant dispatcher must have a documented owner and purpose and must be rotated before production use.
- Previous workflow versions should not remain in the live n8n instance once their repository exports and rollback evidence are preserved.

The self-hosted instance disables diagnostics, personalization, the public API, public workflow templates, community-package installation, unverified packages, and unused Python Code-node execution. Version notifications remain enabled so supported security updates stay visible.

### Runtime audit evidence — 27 August 2026

After the backed-up upgrade from n8n `2.35.5` to `2.36.7`, the native audit completed successfully. Its findings were reviewed as follows:

- the reported PostgreSQL nodes either execute constant control queries or use the repository-reviewed parameterization and persistence contracts for dynamic values;
- the reported Code and HTTP Request nodes are required adapters whose input allow-lists, destination constraints, output validation, timeouts, and sanitized failure paths are covered by repository tests;
- the unused `Microsoft Teams Workflow signature` credential belongs to the intentionally dormant Teams dispatcher and must be deleted if that channel is retired, or rotated before production activation;
- the instance report confirmed that community packages, templates, the public API, and diagnostics are disabled;
- n8n started its internal JavaScript task runner, left Python unavailable, applied its internal migrations, and reactivated the seven expected production workflows.

The audit is a review aid rather than a zero-finding gate. Any new node, credential, or enabled capability requires a fresh disposition.
