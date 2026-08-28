# V1 release checklist

This checklist is the controlled path from the M6 release candidate to the
annotated `v1.0.0` tag. Run it from a clean `main` checkout after every V1 pull
request, including the release demonstration increment, has been merged.

Do not create the tag from a feature branch or while any mandatory item remains
open. Commands in this document are examples for the operator; repository
automation does not create tags or GitHub releases.

## 1. Confirm release scope

- [ ] M0 through M5 are complete and M6 has no unfinished release deliverable.
- [ ] The V1 architecture and threat model match the deployed local topology.
- [ ] The release contains no real victim fixture, stolen content, personal data,
  credential value, webhook signature, API key, or `.env` file.
- [ ] The tagged snapshot, release notes, screenshots, logs, and uploaded
  artifacts contain no private organization watchlist name or domain; every
  bundled organization remains visibly `[Synthetic]` with a `.invalid` domain.
- [ ] The backup-storage decision remains valid for the intended deployment.
- [ ] The release is described as local, single-operator, and evaluation-ready;
  it is not presented as an Internet-facing production service.

## 2. Confirm exact dependencies and artifacts

- [ ] `.env.example`, Compose, README, and security scanning agree on n8n
  `2.36.7` and PostgreSQL `17.10-alpine3.23`.
- [ ] The n8n and PostgreSQL container images are pinned and their current CI
  scans have no unhandled critical finding.
- [ ] Qwen3 `8b-q4_K_M` model name, digest, context limit, and output limit agree
  across the profile, workflow export, tests, and documentation.
- [ ] The documented pre-v1 seed sanitization is complete; the resulting
  migration baseline is frozen, sequential, and represented in a clean
  installation.
- [ ] Every V1 workflow export is sanitized, version controlled, and imports
  without embedded credentials.

## 3. Confirm hosted repository protections

- [ ] The `Protect main` ruleset is active and blocks deletion, force pushes,
  and direct changes without a pull request for non-bypass actors; every bypass
  remains narrowly scoped and documented.
- [ ] Required status checks include `validate`, `Secret history`,
  `Container image (postgres)`, and `Container image (n8n)`.
- [ ] GitHub private vulnerability reporting is enabled.
- [ ] GitHub Secret Scanning and Push Protection are enabled.
- [ ] Dependabot security updates are enabled or their omission is explicitly
  accepted for the release with an owner and review date.

The repository workflows remain authoritative even when a GitHub-hosted feature
is unavailable. A disabled hosted feature must stay visibly open in
`SECURITY.md`; it must not be silently treated as complete.

### Verified repository evidence

On 2026-08-28, the repository API confirmed private vulnerability reporting,
Secret Scanning, Push Protection, and Dependabot security updates were enabled.
The active `Protect main` ruleset required `validate`, `Secret history`,
`Container image (postgres)`, and `Container image (n8n)`. The ruleset also
blocked branch deletion and non-fast-forward updates for non-bypass actors and
required pull requests. Recheck this mutable hosted state immediately before
tagging; this dated evidence is not a permanent guarantee.

## 4. Validate recovery and safe runtime behavior

- [ ] A fresh backup has been created to protected storage and its manifest and
  checksums are present.
- [ ] The original `N8N_ENCRYPTION_KEY` is stored separately in an approved
  password manager.
- [ ] The latest isolated restore exercise still represents the current backup
  contract, or a new exercise has been completed.
- [ ] Notification channels remain disabled unless their dispatcher, credential,
  and destination were deliberately approved together.
- [ ] Exactly one analysis provider is selected and ready; switching providers
  does not silently backfill historical claims.
- [ ] The synthetic demonstration succeeds without contacting a real notification
  destination or retaining its temporary data.
- [ ] The six release-demonstration captures pass the irreversible-redaction
  and metadata review in `release-demonstration.md` and render from a clean clone.

## 5. Run final validation

Windows:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/validate.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/security/scan-secrets.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/security/scan-containers.ps1
git diff --check
git status --short
```

macOS or Linux:

```sh
sh scripts/validate.sh
sh scripts/security/scan-secrets.sh
sh scripts/security/scan-containers.sh
git diff --check
git status --short
```

- [ ] Repository validation passes on the release platform.
- [ ] Secret-history scanning passes.
- [ ] Both container-image gates pass against the exact release images.
- [ ] The latest `main` CI and Security scanning workflows are successful.
- [ ] The working tree is clean and `HEAD` equals `origin/main`.

## 6. Freeze release notes

- [ ] Move the contents of `CHANGELOG.md` from `Unreleased` to
  `1.0.0 - YYYY-MM-DD`.
- [ ] Update README and ROADMAP from M6 in progress to V1 released.
- [ ] Record the exact validation evidence without secrets or raw source data.
- [ ] Review installation, release demonstration, recovery, security, and
  known-limit links from a clean browser session.
- [ ] Merge the final release-documentation pull request and wait for all required
  checks on `main`.

## 7. Create and verify the release

Only after sections 1 through 6 are complete:

```powershell
git switch main
git pull --ff-only origin main
git status --short
git tag -s v1.0.0 -m "Threat Claim Monitor v1.0.0"
git tag --verify v1.0.0
git push origin v1.0.0
```

Use a signed annotated tag. If signing is not configured, stop and configure a
verified signing identity; do not silently replace it with an unsigned tag.

- [ ] The tag resolves to the reviewed `main` commit.
- [ ] GitHub displays the tag signature as verified.
- [ ] A GitHub release is created from `v1.0.0` using the frozen changelog.
- [ ] Release links and installation commands are checked once more.
- [ ] The release evidence contains no secret or sensitive backup material.

## Rollback before and after tagging

Before pushing the tag, correct the release branch through a normal pull
request and repeat the checklist. After pushing `v1.0.0`, never move or overwrite
the tag. Publish a corrective patch release such as `v1.0.1`, or withdraw the
GitHub release while preserving the immutable tag and documenting the reason.
