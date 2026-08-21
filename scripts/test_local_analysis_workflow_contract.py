"""Validate the sanitized WF-40 local-analysis workflow contract."""

from __future__ import annotations

import json
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
WORKFLOW_FILE = ROOT / "n8n/workflows/wf-40-local-analysis.json"
PROFILE_FILE = ROOT / "ai/models/qwen3-8b-q4_K_M.json"
MIGRATION_FILE = ROOT / "db/migrations/010_local_analysis_provenance.sql"
RUNTIME_TEST_FILE = ROOT / "scripts/test_local_analysis_persistence.sql"


def targets(connections: dict, node_name: str, output: int = 0) -> list[str]:
    outputs = connections.get(node_name, {}).get("main", [])
    if len(outputs) <= output:
        return []
    return [item["node"] for item in outputs[output]]


def main() -> int:
    errors: list[str] = []
    workflow = json.loads(WORKFLOW_FILE.read_text(encoding="utf-8"))
    profile = json.loads(PROFILE_FILE.read_text(encoding="utf-8"))
    nodes = {node.get("name"): node for node in workflow.get("nodes", [])}
    connections = workflow.get("connections", {})

    expected_nodes = {
        "Run analysis manually",
        "Run from orchestrator",
        "Load pending analysis jobs",
        "Build Ollama request",
        "Call local Ollama",
        "Validate output or fallback",
        "Build unavailable fallback",
        "Persist analysis result",
    }
    missing = sorted(expected_nodes - nodes.keys())
    if missing:
        errors.append(f"WF-40 is missing nodes: {', '.join(missing)}")
    if workflow.get("active") is not False:
        errors.append("committed WF-40 export must remain inactive")
    if any("credentials" in node for node in workflow.get("nodes", [])):
        errors.append("committed WF-40 export must not contain credential identifiers")

    load_query = nodes.get("Load pending analysis jobs", {}).get("parameters", {}).get("query", "")
    if "get_routed_pending_claim_analysis_jobs('claim-analysis-v1', 'ollama'" not in load_query:
        errors.append("WF-40 must load bounded claim-analysis-v1 jobs")

    build_code = nodes.get("Build Ollama request", {}).get("parameters", {}).get("jsCode", "")
    for fragment in (
        profile["model"],
        profile["expected_digest"],
        "claim-analysis-v1",
        "UNTRUSTED_EVIDENCE",
        "additionalProperties:false",
        "stream:false",
        "think:false",
        "temperature:0",
        "num_ctx:4096",
        "num_predict:512",
    ):
        if fragment not in build_code:
            errors.append(f"Ollama request builder is missing {fragment}")
    if "tools:" in build_code:
        errors.append("WF-40 must never provide model tools")

    call = nodes.get("Call local Ollama", {})
    parameters = call.get("parameters", {})
    if parameters.get("method") != "POST" or "/api/chat" not in parameters.get("url", ""):
        errors.append("WF-40 must call the Ollama chat endpoint with POST")
    if parameters.get("url") != "http://host.docker.internal:11434/api/chat":
        errors.append("WF-40 must use the fixed host-native Ollama chat URL")
    if "$env" in parameters.get("url", ""):
        errors.append("WF-40 must not require n8n node access to environment variables")
    if parameters.get("options", {}).get("timeout") != 180000:
        errors.append("WF-40 Ollama timeout must remain 180 seconds")
    if call.get("onError") != "continueErrorOutput":
        errors.append("Ollama failures must use the dedicated error output")
    if targets(connections, "Call local Ollama", 0) != ["Validate output or fallback"]:
        errors.append("successful Ollama output must be validated")
    if targets(connections, "Call local Ollama", 1) != ["Build unavailable fallback"]:
        errors.append("Ollama errors must create a sanitized fallback")

    validation_code = nodes.get("Validate output or fallback", {}).get("parameters", {}).get(
        "jsCode", ""
    )
    for fragment in (
        "confidence_score",
        "verification_status",
        "auto_alert_eligible",
        "model_output_invalid",
        "evidence_ids",
        "validation_status:valid?'valid':'fallback'",
    ):
        if fragment not in validation_code:
            errors.append(f"output validator is missing {fragment}")

    unavailable_code = nodes.get("Build unavailable fallback", {}).get("parameters", {}).get(
        "jsCode", ""
    )
    if "ollama_unavailable" not in unavailable_code or "validation_status:'fallback'" not in unavailable_code:
        errors.append("Ollama error path must persist the allow-listed fallback")

    persist = nodes.get("Persist analysis result", {}).get("parameters", {})
    if "persist_claim_analysis_result" not in persist.get("query", ""):
        errors.append("WF-40 must persist through the transactional database function")
    if "JSON.stringify($json.persistence)" not in persist.get("options", {}).get(
        "queryReplacement", ""
    ):
        errors.append("WF-40 must bind one JSON persistence envelope")
    if targets(connections, "Validate output or fallback") != ["Persist analysis result"]:
        errors.append("validated output must reach persistence")
    if targets(connections, "Build unavailable fallback") != ["Persist analysis result"]:
        errors.append("unavailable fallback must reach persistence")

    migration = MIGRATION_FILE.read_text(encoding="utf-8")
    for fragment in (
        "FUNCTION validate_claim_analysis_output",
        "FUNCTION build_claim_analysis_input",
        "FUNCTION get_pending_claim_analysis_jobs",
        "FUNCTION persist_claim_analysis_result",
        "encode(digest(resolved_input_payload::text, 'sha256'), 'hex')",
        "analysis output references unknown evidence",
        "local analysis output invalid; deterministic fallback stored",
    ):
        if fragment not in migration:
            errors.append(f"analysis provenance migration is missing {fragment}")

    runtime_test = RUNTIME_TEST_FILE.read_text(encoding="utf-8")
    for fragment in (
        "eligible analysis job has invalid bounded provenance",
        "analysis persistence must be idempotent",
        "stored analysis provenance is incomplete",
        "ROLLBACK;",
    ):
        if fragment not in runtime_test:
            errors.append(f"analysis persistence runtime test is missing {fragment}")

    if errors:
        print("Local-analysis workflow contract validation failed:", file=sys.stderr)
        for error in errors:
            print(f"- {error}", file=sys.stderr)
        return 1
    print("Local-analysis workflow contract validation passed (selection, Ollama, fallback, provenance).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
