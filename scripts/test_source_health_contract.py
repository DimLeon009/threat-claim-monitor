"""Validate M5 source health, switches, and isolated orchestration contracts."""

from __future__ import annotations

import json
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MIGRATION = ROOT / "db/migrations/021_source_health_and_switches.sql"
RUNTIME_TEST = ROOT / "scripts/test_source_health_contract.sql"
ORCHESTRATOR = ROOT / "n8n/workflows/wf-00-orchestrator.json"


def targets(connections: dict[str, object], node_name: str) -> list[str]:
    outputs = connections.get(node_name, {}).get("main", [])
    if not outputs:
        return []
    return [target["node"] for target in outputs[0]]


def main() -> int:
    errors: list[str] = []
    migration = MIGRATION.read_text(encoding="utf-8")
    runtime_test = RUNTIME_TEST.read_text(encoding="utf-8")
    workflow = json.loads(ORCHESTRATOR.read_text(encoding="utf-8"))
    nodes = {node.get("name"): node for node in workflow.get("nodes", [])}
    connections = workflow.get("connections", {})

    for fragment in (
        "CREATE OR REPLACE VIEW source_health",
        "last_success_at",
        "last_failure_at",
        "consecutive_failure_count",
        "latest_response_validation",
        "latest_contract_version",
        "latest_fetched_count",
        "latest_inserted_count",
        "WHEN source.enabled = false THEN 'disabled'",
        "WHEN latest_run.id IS NULL THEN 'never_run'",
        "THEN 'degraded'",
        "THEN 'stale'",
        "ELSE 'healthy'",
        "CREATE OR REPLACE FUNCTION set_source_enabled",
        "source state change reason contains prohibited secret-like material",
        "operational_state_change_reason",
        "021_source_health_and_switches",
    ):
        if fragment not in migration:
            errors.append(f"source-health migration is missing: {fragment}")

    for fragment in (
        "degraded source health summary is invalid",
        "disabled source health state is invalid",
        "unsafe source state reason was accepted",
        "recovered source health summary is invalid",
        "ROLLBACK;",
    ):
        if fragment not in runtime_test:
            errors.append(f"source-health runtime test is missing: {fragment}")

    expected_nodes = {
        "Check ransomware.live enabled",
        "Check RansomLook enabled",
        "Collect ransomware.live",
        "Collect RansomLook",
    }
    missing_nodes = sorted(expected_nodes - nodes.keys())
    if missing_nodes:
        errors.append(f"WF-00 is missing nodes: {', '.join(missing_nodes)}")

    expected_fanout = {"Check ransomware.live enabled", "Check RansomLook enabled"}
    for trigger in ("Run orchestration manually", "Run every 15 minutes"):
        if set(targets(connections, trigger)) != expected_fanout:
            errors.append(f"{trigger} must fan out to both independent source gates")

    gate_targets = {
        "Check ransomware.live enabled": "Collect ransomware.live",
        "Check RansomLook enabled": "Collect RansomLook",
    }
    for gate, collector in gate_targets.items():
        query = nodes.get(gate, {}).get("parameters", {}).get("query", "")
        if "FROM sources" not in query or "enabled = true" not in query:
            errors.append(f"{gate} must load its database enable switch")
        if targets(connections, gate) != [collector]:
            errors.append(f"{gate} must target only {collector}")

    for collector in ("Collect ransomware.live", "Collect RansomLook"):
        node = nodes.get(collector, {})
        if node.get("onError") != "continueRegularOutput":
            errors.append(f"{collector} must isolate sub-workflow failure")
        if node.get("parameters", {}).get("workflowId") != "":
            errors.append(f"{collector} export must not contain a local workflow identifier")

    if workflow.get("active") is not False:
        errors.append("committed WF-00 export must remain inactive")
    if any("credentials" in node for node in workflow.get("nodes", [])):
        errors.append("committed WF-00 export must not contain credential identifiers")

    if errors:
        print("Source health and orchestration contract validation failed:", file=sys.stderr)
        for error in errors:
            print(f"- {error}", file=sys.stderr)
        return 1

    print("Source health and orchestration contract validation passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
