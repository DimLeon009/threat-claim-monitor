#!/usr/bin/env python3
"""Validate exclusive, explicit, non-retroactive analysis-provider routing."""

from __future__ import annotations

import json
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MIGRATION = (ROOT / "db/migrations/026_analysis_provider_routing.sql").read_text(
    encoding="utf-8"
)
RUNTIME_TEST = (ROOT / "scripts/test_analysis_provider_routing_contract.sql").read_text(
    encoding="utf-8"
)
ORCHESTRATOR = json.loads(
    (ROOT / "n8n/workflows/wf-00-orchestrator.json").read_text(encoding="utf-8")
)
LOCAL = json.loads(
    (ROOT / "n8n/workflows/wf-40-local-analysis.json").read_text(encoding="utf-8")
)
FOUNDRY = json.loads(
    (ROOT / "n8n/workflows/wf-41-microsoft-foundry-analysis.json").read_text(
        encoding="utf-8"
    )
)


def targets(connections: dict[str, object], node_name: str) -> list[str]:
    outputs = connections.get(node_name, {}).get("main", [])
    if not outputs:
        return []
    return [target["node"] for target in outputs[0]]


def main() -> int:
    errors: list[str] = []

    for fragment in (
        "CREATE TABLE IF NOT EXISTS analysis_routing_policy",
        "CHECK (selected_provider IN ('ollama', 'microsoft_foundry'))",
        "DEFAULT 'ollama'",
        "effective_from timestamptz",
        "CREATE OR REPLACE FUNCTION get_analysis_routing_decision",
        "CREATE OR REPLACE FUNCTION set_analysis_routing_provider",
        "Microsoft Foundry routing requires an enabled reviewed provider configuration",
        "analysis routing reason contains prohibited secret-like material",
        "CREATE OR REPLACE FUNCTION get_routed_pending_claim_analysis_jobs",
        "claim.updated_at >= route.effective_from",
        "decision.route_ready = true",
        "analysis.provider = requested_provider",
        "analysis.deployment_name = requested_deployment_name",
        "026_analysis_provider_routing",
    ):
        if fragment not in MIGRATION:
            errors.append(f"analysis routing migration is missing: {fragment}")

    for forbidden in ("dual", "automatic fallback", "auto_fallback"):
        if forbidden in MIGRATION.lower():
            errors.append(f"analysis routing migration introduces a prohibited mode: {forbidden}")

    for fragment in (
        "local route did not isolate provider jobs",
        "provider switch performed an implicit historical backfill",
        "cloud route is not exclusive or idempotent",
        "disabled Foundry route did not fail closed",
        "unsafe routing reason was accepted",
        "ROLLBACK;",
        "Analysis provider routing runtime validation passed.",
    ):
        if fragment not in RUNTIME_TEST:
            errors.append(f"analysis routing runtime test is missing: {fragment}")

    nodes = {node.get("name"): node for node in ORCHESTRATOR.get("nodes", [])}
    connections = ORCHESTRATOR.get("connections", {})
    expected_analysis_nodes = {
        "Run analysis every minute",
        "Check local analysis selected",
        "Check Foundry analysis selected",
        "Run local analysis",
        "Run Foundry analysis",
    }
    missing_nodes = sorted(expected_analysis_nodes - nodes.keys())
    if missing_nodes:
        errors.append(f"WF-00 is missing analysis routing nodes: {', '.join(missing_nodes)}")

    expected_gates = {
        "Check local analysis selected",
        "Check Foundry analysis selected",
    }
    if set(targets(connections, "Run analysis every minute")) != expected_gates:
        errors.append("Run analysis every minute must evaluate both exclusive database gates")
    if not expected_gates.issubset(
        set(targets(connections, "Run orchestration manually"))
    ):
        errors.append("manual orchestration must also evaluate both analysis gates")

    routes = {
        "Check local analysis selected": ("'ollama'", "Run local analysis"),
        "Check Foundry analysis selected": (
            "'microsoft_foundry'", "Run Foundry analysis"
        ),
    }
    for gate, (provider, runner) in routes.items():
        query = nodes.get(gate, {}).get("parameters", {}).get("query", "")
        if "get_analysis_routing_decision()" not in query \
                or "route_ready = true" not in query or provider not in query:
            errors.append(f"{gate} does not enforce its reviewed ready provider")
        if targets(connections, gate) != [runner]:
            errors.append(f"{gate} must invoke only {runner}")
        runner_node = nodes.get(runner, {})
        if runner_node.get("onError") != "continueRegularOutput":
            errors.append(f"{runner} must isolate provider workflow failure")
        if runner_node.get("parameters", {}).get("workflowId") != "":
            errors.append(f"{runner} export must not contain a local workflow identifier")

    schedule = nodes.get("Run analysis every minute", {}).get("parameters", {})
    if "minutesInterval\": 1" not in json.dumps(schedule):
        errors.append("WF-00 analysis queue must be consumed every minute")
    if ORCHESTRATOR.get("active") is not False:
        errors.append("committed WF-00 export must remain inactive")
    if any("credentials" in node for node in ORCHESTRATOR.get("nodes", [])):
        errors.append("committed WF-00 export must not contain credential identifiers")

    local_query = next(
        node for node in LOCAL["nodes"] if node["name"] == "Load pending analysis jobs"
    )["parameters"]["query"]
    foundry_query = next(
        node for node in FOUNDRY["nodes"] if node["name"] == "Load configured Foundry jobs"
    )["parameters"]["query"]
    if "get_routed_pending_claim_analysis_jobs" not in local_query \
            or "'ollama'" not in local_query:
        errors.append("WF-40 does not consume only routed local jobs")
    if "get_routed_pending_claim_analysis_jobs" not in foundry_query \
            or "'microsoft_foundry'" not in foundry_query:
        errors.append("WF-41 does not consume only routed Foundry jobs")
    if "microsoft_foundry" in json.dumps(LOCAL).lower():
        errors.append("WF-40 contains an implicit local-to-cloud path")

    if errors:
        print("Analysis provider routing contract validation failed:", file=sys.stderr)
        for error in errors:
            print(f"- {error}", file=sys.stderr)
        return 1

    print("Analysis provider routing contract validation passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
