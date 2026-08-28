#!/usr/bin/env python3
"""Validate the repository-owned V1 release-readiness contract."""

from __future__ import annotations

import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def read(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8")


def require(condition: bool, message: str, errors: list[str]) -> None:
    if not condition:
        errors.append(message)


def main() -> int:
    errors: list[str] = []
    changelog = read("CHANGELOG.md")
    checklist = read("docs/operations/v1-release-checklist.md")
    decision = read("docs/security/backup-storage-decision.md")
    backup = read("docs/operations/backup-and-restore.md")
    roadmap = read("ROADMAP.md")
    security = read("SECURITY.md")
    readme = read("README.md")
    docs_index = read("docs/README.md")
    data_model = read("docs/architecture/data-model.md")
    getting_started = read("docs/operations/getting-started.md")
    environment = read(".env.example")
    compose = read("docker-compose.yml")
    security_workflow = read(".github/workflows/security.yml")
    support = read("SUPPORT.md")
    workflow_deployment = read("docs/operations/workflow-deployment.md")
    remote_administration = read("docs/operations/remote-administration.md")

    for fragment in (
        "## [Unreleased]",
        "### Added",
        "### Security",
        "### Operations",
        "The release commit will replace `Unreleased` with `1.0.0`",
    ):
        require(fragment in changelog, f"changelog is missing: {fragment}", errors)

    for fragment in (
        "Do not create the tag from a feature branch",
        "GitHub private vulnerability reporting is enabled",
        "GitHub Secret Scanning and Push Protection are enabled",
        "Container image (postgres)",
        "Container image (n8n)",
        "On 2026-08-28, the repository API confirmed",
        "git tag -s v1.0.0",
        "git tag --verify v1.0.0",
        "never move or overwrite",
    ):
        require(fragment in checklist, f"release checklist is missing: {fragment}", errors)

    for fragment in (
        "Accepted for the local V1 scope; production deployment remains gated",
        "full-disk-encrypted operator device",
        "production deployment is prohibited",
        "separation of the backup from `N8N_ENCRYPTION_KEY`",
        "recovery point objective",
        "recovery time objective",
    ):
        require(fragment in decision, f"backup-storage decision is missing: {fragment}", errors)

    require("backup-storage decision" in backup, "backup runbook omits the storage decision", errors)
    require("[Changelog](CHANGELOG.md)" not in readme, "README uses an unexpected changelog label", errors)
    require("[changelog](CHANGELOG.md)" in readme, "README does not link the changelog", errors)
    require("v1-release-checklist.md" in readme, "README does not link the release checklist", errors)
    require("v1-release-checklist.md" in docs_index, "documentation index omits release checklist", errors)
    require("backup-storage-decision.md" in docs_index, "documentation index omits storage decision", errors)
    require("workflow-deployment.md" in docs_index, "documentation index omits workflow deployment", errors)
    require("remote-administration.md" in docs_index, "documentation index omits remote administration", errors)
    require("security/advisories/new" in support, "support guide omits private vulnerability reporting", errors)
    require("13 sanitized" in workflow_deployment or "13 |" in workflow_deployment,
            "workflow deployment does not cover all exports", errors)
    require("SSH tunnel" in remote_administration,
            "remote administration omits the private administration path", errors)

    for fragment in (
        "- [x] Release checklist and changelog",
        "- [x] Enable hosted GitHub security controls",
        "- [ ] Tag and publish `v1.0.0`",
    ):
        require(fragment in roadmap, f"roadmap release state is missing: {fragment}", errors)

    for control in (
        "Enable GitHub private vulnerability reporting",
        "Enable repository secret scanning",
        "Enable repository push protection",
        "Enable Dependabot security updates",
    ):
        require(
            f"- [x] {control}." in security,
            f"security checklist omits hosted control: {control}",
            errors,
        )

    require(
        "Retention will become configurable before v1.0.0" not in data_model,
        "data model still describes implemented retention as future work",
        errors,
    )
    require(
        "Backup and restore procedures will be formalized before v1.0.0" not in getting_started,
        "getting-started guide still describes implemented recovery as future work",
        errors,
    )

    version_contracts = (
        ("N8N_VERSION=2.36.7", environment, ".env.example n8n version"),
        ("${N8N_VERSION:-2.36.7}", compose, "Compose n8n default"),
        ("docker.n8n.io/n8nio/n8n:2.36.7", security_workflow, "scanned n8n image"),
        ("POSTGRES_VERSION=17.10-alpine3.23", environment, ".env.example PostgreSQL version"),
        ("${POSTGRES_VERSION:-17.10-alpine3.23}", compose, "Compose PostgreSQL default"),
        ("postgres:17.10-alpine3.23", security_workflow, "scanned PostgreSQL image"),
    )
    for fragment, content, label in version_contracts:
        require(fragment in content, f"release dependency contract differs: {label}", errors)

    if errors:
        print("V1 release-readiness contract validation failed:", file=sys.stderr)
        for error in errors:
            print(f"- {error}", file=sys.stderr)
        return 1

    print("V1 release-readiness contract validation passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
