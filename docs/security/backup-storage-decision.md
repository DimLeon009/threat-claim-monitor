# Backup-storage decision for V1

**Decision date:** 2026-08-28

**Status:** Accepted for the local V1 scope; production deployment remains gated

## Decision

Threat Claim Monitor V1 is a local, single-operator, portfolio and internal
evaluation release. Repository tooling creates integrity-checked backups but
does not encrypt them. The release therefore does not claim production backup
storage or authorize an Internet-facing or shared production deployment.

For the V1 scope, backup directories may be retained only on an access-controlled,
full-disk-encrypted operator device or in organization-approved encrypted
storage. They must remain outside Git, repository attachments, email, public
cloud links, and unapproved synchronized folders. `N8N_ENCRYPTION_KEY` must be
kept separately in an approved password manager.

Disposable restoration-test backups must be removed after evidence has been
recorded unless they are deliberately promoted to protected storage.

## Production gate

Before any production or shared deployment, the owner must select and document
an organization-approved backup destination that provides:

- encryption at rest and in transit;
- least-privilege access and access revocation;
- retention and secure-deletion controls;
- an off-device or off-site recovery copy;
- monitoring or audit records for access and deletion;
- separation of the backup from `N8N_ENCRYPTION_KEY` and other recovery secrets;
- a defined recovery point objective, recovery time objective, and recurring
  restore exercise.

If these requirements are not met, production deployment is prohibited. This
is an explicit scope decision, not an assertion that repository-local backups
are sufficiently protected for production.

## Consequences

- The local V1 release can demonstrate verified backup and recovery without
  adding a cloud-storage dependency or embedding encryption keys in scripts.
- Backup confidentiality remains an operator responsibility for local use.
- A future production-storage integration requires its own architecture and
  security review, credentials, retention rules, and failure-mode tests.
