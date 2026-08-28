#!/usr/bin/env python3
"""Check that operator documentation matches the implemented repository."""

from __future__ import annotations

import json
import re
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
    deployment = read("docs/operations/workflow-deployment.md")
    getting_started = read("docs/operations/getting-started.md")
    data_model = read("docs/architecture/data-model.md")
    remote = read("docs/operations/remote-administration.md")
    support = read("SUPPORT.md")
    local_ai = read("docs/ai/local-analysis-contract.md")

    workflow_paths = sorted((ROOT / "n8n" / "workflows").glob("*.json"))
    require(len(workflow_paths) == 13, "workflow deployment count is no longer 13", errors)
    workflow_names: set[str] = set()
    for path in workflow_paths:
        workflow = json.loads(path.read_text(encoding="utf-8"))
        name = workflow.get("name")
        require(isinstance(name, str) and bool(name), f"{path.name} has no workflow name", errors)
        if isinstance(name, str):
            workflow_names.add(name)
            require(path.name in deployment, f"workflow deployment omits {path.name}", errors)
            require(name in deployment, f"workflow deployment omits workflow name {name}", errors)
        node_names = [node.get("name") for node in workflow.get("nodes", [])]
        require(all(isinstance(node_name, str) and node_name.strip() for node_name in node_names),
                f"{path.name} contains an unnamed node", errors)
        require(len(node_names) == len(set(node_names)),
                f"{path.name} contains duplicate node names", errors)
        for node_name in node_names:
            if isinstance(node_name, str):
                require(re.fullmatch(r"(?:Postgres|Code|HTTP Request|IF|Edit Fields)\d*", node_name) is None,
                        f"{path.name} contains a generic node name: {node_name}", errors)

    expected_mappings = {
        "Collect ransomware.live": "WF-10 Collect ransomware.live",
        "Collect RansomLook": "WF-11 Collect RansomLook",
        "Collect FrenchBreaches": "WF-12 Collect FrenchBreaches RSS",
        "Run local analysis": "WF-40 Local analysis",
        "Run Foundry analysis": "WF-41 Microsoft Foundry analysis",
    }
    orchestrator = json.loads(read("n8n/workflows/wf-00-orchestrator.json"))
    orchestrator_nodes = {node.get("name") for node in orchestrator.get("nodes", [])}
    for node_name, target in expected_mappings.items():
        require(node_name in orchestrator_nodes, f"WF-00 node is missing: {node_name}", errors)
        require(node_name in deployment and target in deployment,
                f"workflow deployment omits mapping {node_name} -> {target}", errors)
        require(target in workflow_names, f"mapped target workflow is missing: {target}", errors)

    migration_paths = sorted((ROOT / "db" / "migrations").glob("*.sql"))
    versions = [int(path.name[:3]) for path in migration_paths]
    require(versions == list(range(1, len(versions) + 1)), "migration sequence has a gap", errors)
    require(len(migration_paths) == 26, "documented migration count is no longer 26", errors)
    require(re.search(r"all\s+26 migrations", getting_started) is not None,
            "getting started omits migration count", errors)

    tables: set[str] = set()
    for path in migration_paths:
        sql = path.read_text(encoding="utf-8")
        tables.update(re.findall(r"CREATE TABLE IF NOT EXISTS\s+([a-z0-9_]+)", sql, re.I))
    for table in sorted(tables):
        require(f"`{table}`" in data_model, f"data model omits table {table}", errors)

    for view in (
        "source_health",
        "operational_source_dashboard",
        "operational_notification_dashboard",
        "operational_dashboard_summary",
    ):
        require(f"`{view}`" in data_model, f"data model omits view {view}", errors)
    require("eligible for clearing after 180 days" not in data_model,
            "data model documents unimplemented raw-payload deletion", errors)
    require("removes only eligible terminal" in data_model,
            "data model does not state the implemented retention boundary", errors)

    for fragment in ("no Threat Claim Monitor workflows", "credentials",
                     "workflow-deployment.md", "silent baselines",
                     "Repository validation passed."):
        require(fragment in getting_started, f"getting started omits: {fragment}", errors)

    for fragment in (
        "ssh -N -L 15678:127.0.0.1:5678",
        "Do not\nchange the Compose binding to `0.0.0.0`",
        "N8N_EDITOR_BASE_URL",
        "WEBHOOK_URL",
        "N8N_PROXY_HOPS",
        "external task runners",
    ):
        require(fragment in remote, f"remote administration omits: {fragment}", errors)

    for fragment in (
        "issues/new?template=help_request.yml",
        "issues/new?template=bug_report.yml",
        "issues/new?template=feature_request.yml",
        "issues/new?template=task.yml",
        "security/advisories/new",
        "A pull request is not a support channel",
    ):
        require(fragment in support, f"support routing omits: {fragment}", errors)

    for template in ("help_request.yml", "bug_report.yml", "feature_request.yml", "task.yml"):
        require((ROOT / ".github" / "ISSUE_TEMPLATE" / template).is_file(),
                f"issue template is missing: {template}", errors)

    local_workflow = read("n8n/workflows/wf-40-local-analysis.json")
    require("keep_alive:'5m'" in local_workflow, "WF-40 keep-alive contract changed", errors)
    require("`5m` keep-alive" in local_ai, "local AI documentation differs from WF-40 keep-alive", errors)

    stale_phrases = (
        "When Milestone 3 begins",
        "from Milestone 3 onward",
        "next M2 increment",
        "External delivery is still absent from this increment",
    )
    documentation = "\n".join(
        path.read_text(encoding="utf-8")
        for path in [ROOT / "README.md", ROOT / "SUPPORT.md", *(ROOT / "docs").rglob("*.md")]
    )
    for phrase in stale_phrases:
        require(phrase not in documentation, f"stale documentation phrase remains: {phrase}", errors)

    if errors:
        print("Documentation coherence validation failed:", file=sys.stderr)
        for error in errors:
            print(f"- {error}", file=sys.stderr)
        return 1

    print("Documentation coherence validation passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
