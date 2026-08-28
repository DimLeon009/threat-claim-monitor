# V1 architecture and threat-model review

- **Review date:** 2026-08-21
- **Last evidence update:** 2026-08-28
- **Scope:** repository state after migrations 001–026 and all committed workflows WF-00–WF-99
- **Status:** Completed with open release-readiness and production gates

## Review objective

Verify that the documented V1 architecture and threat model match the deployed
single-host design, identify material gaps without hiding them, and establish
explicit gates for the v1.0.0 release.

Completing this review does not mean every residual risk is closed. It means the
implemented controls, accepted limitations, and unresolved release blockers are
recorded and testable.

## Evidence reviewed

- Docker Compose service, network, port, volume, and environment configuration;
- all committed n8n workflow exports from WF-00 through WF-71;
- PostgreSQL migrations 001–026 and the data-model documentation;
- source, matching, inference, notification, backup, retention, dashboard, and
  failure-mode contracts;
- ADR-0001 and ADR-0002;
- Windows runtime validation evidence recorded in project documentation;
- current roadmap and security validation checklist.

Runtime credentials, secret values, private endpoints, customer data, and n8n
database contents were intentionally outside the repository review.

## Confirmed architecture

| Area | Reviewed state | Result |
|---|---|---|
| Services | n8n and PostgreSQL in Compose; Ollama on the host; Foundry optional | Matches ADRs |
| Host exposure | n8n bound to `127.0.0.1`; PostgreSQL has no published port | Acceptable for single-host V1 |
| Networks | PostgreSQL on internal backend; n8n alone also joins outbound | Least-exposure intent confirmed |
| Evidence | Observations precede correlation, matching, analysis, and notification | Lineage preserved |
| Decisions | Matching, verification, routing, and notification eligibility remain deterministic | Model authority excluded |
| Inference | Explicit Ollama or Foundry selection; no silent local-to-cloud fallback | Cloud boundary controlled |
| Delivery | Transactional outbox, leases, bounded retries, dead-letter, immutable attempts | At-least-once risk documented |
| Recovery | Dual-database and n8n-volume backup with isolated restore validation | Recoverability demonstrated on Windows |
| Retention | Disabled by default, bounded, previewable, audited, evidence-preserving | Destructive boundary constrained |
| Observability | Read-only source, channel, and summary views exclude unsafe detail | Operator visibility available |

## Findings and decisions

| ID | Severity | Finding | Decision or required action | Status |
|---|---|---|---|---|
| F-01 | High | The original WF-00 export invoked collectors but not WF-40 or WF-41 | Migration 026 and the updated WF-00 now select exactly one ready provider every minute, with no dual mode, implicit fallback, or historical backfill | Closed |
| F-02 | Critical when exploitable | A stable n8n image must not ship with an unresolved critical container or sandbox finding | n8n 2.36.7 passed the pinned container gate with no critical finding; the native audit and localhost-only runtime were reviewed | Closed |
| F-03 | Medium | Notification channels and dispatchers are separate runtime switches | Keep each channel disabled until its dispatcher, credential, and destination are reviewed together | Controlled operational gate |
| F-04 | Medium | Backup confidentiality depends on operator-managed storage | Local V1 is limited to protected operator storage; production is prohibited until the accepted backup-storage decision is satisfied | Controlled production gate |
| F-05 | Medium | Apple Silicon installation had not been validated for the release candidate | Native ARM64 containers, localhost exposure, Ollama connectivity, repository validation, and backup were verified on Apple Silicon | Closed |
| F-06 | Low | Workflow exports are intentionally inactive and credential-free, so Git cannot prove runtime publication state | Retain import and runtime verification steps in operations documentation | Accepted |
| F-07 | Low | Operational dashboards are diagnostic snapshots without paging or remediation | Require operator investigation; do not add automatic requeue or source enablement | Accepted |
| F-08 | High | Source-derived values could become SQL query text if a workflow were changed without parameterization review | All 33 PostgreSQL nodes are inventoried; 17 use positional parameters, 16 are fixed, migrations contain no dynamic SQL, and CI rejects unreviewed changes | Closed |

## Trust-boundary conclusions

### Internet sources

The source boundary is attacker-controlled. Adapters use fixed configured
endpoints, HTTPS, bounded retries and item counts, allow-listed fields, schema
validation, normalization, and sanitized failure persistence. Extracted URLs are
not automatically followed.

### PostgreSQL

PostgreSQL is not host-published. Constraints, fixed functions, query
replacement parameters, transaction boundaries, and immutable migrations form
the durable validation layer. The complete source-derived SQL review inventories
every PostgreSQL workflow node, prohibits expression interpolation in SQL text,
and rejects dynamic SQL in migrations through an automated repository contract.

### Local and cloud inference

Both providers receive bounded evidence and return untrusted structured output.
They have no tools or authority over matching, verification, or routing. Foundry
adds credential, region, quota, cost, and processing-scope risks; selection must
remain explicit and provenance must remain stored.

### Notification channels

Payload construction and eligibility are durable before delivery. Rendering is
channel-specific and source text is escaped. Delivery remains at-least-once, so
receivers should use the stable alert ID for idempotency.

### Operator, backups, and destructive actions

The local operator is trusted and can publish workflows, assign credentials,
enable channels, change retention, and restore data. Compromise or error at this
boundary can bypass application-level controls. Host access, backup permissions,
and encryption therefore remain deployment responsibilities.

## Release recommendation

The architecture is coherent for a localhost-only, single-operator V1 and the
threat model now covers every implemented external and destructive boundary.

Do not tag v1.0.0 until the remaining release-readiness tasks and applicable
production gates are closed or explicitly accepted with documented rationale.
The selected n8n image, Windows and Apple Silicon installations, and exclusive
analysis invocation route have now passed their runtime validation. The complete
source-derived SQL review is closed. The backup-storage decision is accepted for
the local release scope and remains a mandatory production control. Hosted
GitHub security settings and required security checks were verified on
2026-08-28. The remaining release checklist and portfolio-demonstration work
must be completed before tagging.

## Review triggers

Repeat this review when any of the following occurs:

- a service or host-published port is added;
- the deployment becomes multi-user or Internet-facing;
- another inference provider, source class, or data category is introduced;
- direct criminal-infrastructure access or stolen-content handling is proposed;
- credentials move outside the current `.env` and n8n stores;
- retention expands beyond empty collection-run metadata;
- a critical dependency or container finding is identified;
- the v1.0.0 release candidate changes its n8n or PostgreSQL major version.
