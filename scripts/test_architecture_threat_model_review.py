#!/usr/bin/env python3
"""Validate that the V1 architecture and threat review matches repository state."""

from __future__ import annotations

import json
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
ARCHITECTURE = (ROOT / "docs/architecture/architecture.md").read_text(encoding="utf-8")
THREAT_MODEL = (ROOT / "docs/security/threat-model.md").read_text(encoding="utf-8")
REVIEW = (ROOT / "docs/security/v1-architecture-threat-review.md").read_text(
    encoding="utf-8"
)
SECURITY = (ROOT / "SECURITY.md").read_text(encoding="utf-8")
COMPOSE = (ROOT / "docker-compose.yml").read_text(encoding="utf-8")
ROADMAP = (ROOT / "ROADMAP.md").read_text(encoding="utf-8")
WORKFLOW_DIRECTORY = ROOT / "n8n/workflows"


def main() -> int:
    errors: list[str] = []

    expected_workflows = {
        "WF-00 Orchestrator",
        "WF-10 Collect ransomware.live",
        "WF-11 Collect RansomLook",
        "WF-12 Collect FrenchBreaches RSS",
        "WF-40 Local analysis",
        "WF-41 Microsoft Foundry analysis",
        "WF-50 Build notification outbox",
        "WF-60 Dispatch generic webhook",
        "WF-61 Dispatch SMTP email",
        "WF-62 Dispatch Teams Workflows",
        "WF-70 Configurable retention",
        "WF-71 Operational dashboards",
        "WF-99 Receive synthetic demo webhook",
    }
    exported_workflows = {
        json.loads(path.read_text(encoding="utf-8")).get("name")
        for path in WORKFLOW_DIRECTORY.glob("wf-*.json")
    }
    if exported_workflows != expected_workflows:
        errors.append("reviewed workflow inventory does not match committed exports")

    for workflow_name in expected_workflows - {"WF-99 Receive synthetic demo webhook"}:
        short_name = workflow_name.split(" ", 1)[0]
        if short_name not in ARCHITECTURE:
            errors.append(f"architecture topology omits workflow family: {short_name}")

    for stale_name in ("WF-20", "WF-30", "WF-90"):
        if stale_name in ARCHITECTURE:
            errors.append(f"architecture still claims a nonexistent workflow: {stale_name}")

    for fragment in (
        '"127.0.0.1:${N8N_PORT:-5678}:5678"',
        "backend:\n    internal: true",
        "networks:\n      - backend\n      - outbound",
    ):
        if fragment not in COMPOSE:
            errors.append(f"reviewed Compose exposure invariant is missing: {fragment}")
    postgres_section = COMPOSE.split("  n8n:", 1)[0]
    if "ports:" in postgres_section:
        errors.append("PostgreSQL unexpectedly publishes a host port")
    if "/var/run/docker.sock" in COMPOSE or "privileged: true" in COMPOSE.lower():
        errors.append("Compose violates the reviewed container privilege boundary")

    for fragment in (
        "Microsoft Foundry cloud boundary",
        "Compromised n8n image or JavaScript sandbox dependency",
        "Backup disclosure or unusable restore",
        "Unsafe retention or misleading dashboard state",
        "## Residual risk register",
        "R-01",
        "R-02",
        "R-06",
    ):
        if fragment not in THREAT_MODEL:
            errors.append(f"threat model is missing reviewed risk material: {fragment}")

    for fragment in (
        "Status:** Completed with open release gates",
        "F-01",
        "F-02",
        "F-05",
        "Do not tag v1.0.0",
        "Migration 026",
        "selected n8n image",
    ):
        if fragment not in REVIEW:
            errors.append(f"formal review is missing a release conclusion: {fragment}")

    if "- [x] Architecture and threat-model review" not in ROADMAP:
        errors.append("roadmap does not record the completed formal review")

    for completed_check in (
        "Test source response-size limits and malformed schemas",
        "Run prompt-injection regression tests",
        "Test notification retry and dead-letter behavior",
        "Complete backup and restore exercise",
        "Review retention and deletion behavior",
    ):
        if f"- [x] {completed_check}." not in SECURITY:
            errors.append(f"security checklist is stale: {completed_check}")

    if errors:
        print("Architecture and threat-model review validation failed:", file=sys.stderr)
        for error in errors:
            print(f"- {error}", file=sys.stderr)
        return 1

    print("Architecture and threat-model review validation passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
