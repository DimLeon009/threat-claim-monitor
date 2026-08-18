"""Validate the sanitized WF-41 Microsoft Foundry workflow contract."""

from __future__ import annotations

import json
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
WORKFLOW_FILE = ROOT / "n8n/workflows/wf-41-microsoft-foundry-analysis.json"
PROFILE_FILE = ROOT / "ai/providers/microsoft-foundry.json"
CONFIG_MIGRATION_FILE = ROOT / "db/migrations/012_foundry_provider_configuration.sql"
CONFIG_TEST_FILE = ROOT / "scripts/test_foundry_provider_configuration.sql"


def targets(connections: dict, node_name: str, output: int = 0) -> list[str]:
    outputs = connections.get(node_name, {}).get("main", [])
    if len(outputs) <= output:
        return []
    return [item["node"] for item in outputs[output]]


def main() -> int:
    errors: list[str] = []
    workflow = json.loads(WORKFLOW_FILE.read_text(encoding="utf-8"))
    profile = json.loads(PROFILE_FILE.read_text(encoding="utf-8"))
    migration = CONFIG_MIGRATION_FILE.read_text(encoding="utf-8")
    runtime_test = CONFIG_TEST_FILE.read_text(encoding="utf-8")
    nodes = {node.get("name"): node for node in workflow.get("nodes", [])}
    connections = workflow.get("connections", {})

    expected_nodes = {
        "Run Foundry analysis manually",
        "Run from orchestrator",
        "Load configured Foundry jobs",
        "Build Foundry request",
        "Call Microsoft Foundry",
        "Validate Foundry output or fallback",
        "Build sanitized Foundry fallback",
        "Persist Foundry analysis",
    }
    missing = sorted(expected_nodes - nodes.keys())
    if missing:
        errors.append(f"WF-41 is missing nodes: {', '.join(missing)}")
    if workflow.get("active") is not False:
        errors.append("committed WF-41 export must remain inactive")
    if any("credentials" in node for node in workflow.get("nodes", [])):
        errors.append("committed WF-41 export must not contain credential identifiers")

    load_query = nodes.get("Load configured Foundry jobs", {}).get("parameters", {}).get(
        "query", ""
    )
    for fragment in (
        "get_enabled_microsoft_foundry_config()",
        "get_pending_claim_analysis_jobs('claim-analysis-v1', 'microsoft_foundry'",
        "config.deployment_name",
    ):
        if fragment not in load_query:
            errors.append(f"WF-41 job query is missing {fragment}")

    build_code = nodes.get("Build Foundry request", {}).get("parameters", {}).get(
        "jsCode", ""
    )
    for fragment in (
        "claim-analysis-v1",
        "UNTRUSTED_EVIDENCE",
        "additionalProperties:false",
        "openai-v1",
        "openai\\.azure\\.com",
        "services\\.ai\\.azure\\.com",
        "/openai/v1/chat/completions",
        "temperature:0",
        "max_completion_tokens:512",
        "stream:false",
        "response_format:{type:'json_schema'",
        "strict:true",
    ):
        if fragment not in build_code:
            errors.append(f"Foundry request builder is missing {fragment}")
    if "tools:" in build_code:
        errors.append("WF-41 must never provide model tools")
    if "api-key" in build_code.lower() or "authorization" in build_code.lower():
        errors.append("WF-41 request code must not construct authentication headers")

    call = nodes.get("Call Microsoft Foundry", {})
    parameters = call.get("parameters", {})
    if parameters.get("method") != "POST":
        errors.append("WF-41 must call Foundry with POST")
    if parameters.get("url") != "={{ $json.foundry_url }}":
        errors.append("WF-41 must use the database-validated Foundry URL")
    if parameters.get("authentication") != "genericCredentialType":
        errors.append("WF-41 must require an n8n generic credential")
    if parameters.get("genericAuthType") != "httpHeaderAuth":
        errors.append("WF-41 prototype must use an n8n HTTP Header Auth credential")
    if parameters.get("options", {}).get("timeout") != 180000:
        errors.append("WF-41 Foundry timeout must remain 180 seconds")
    if call.get("onError") != "continueErrorOutput":
        errors.append("Foundry failures must use the dedicated error output")
    if targets(connections, "Call Microsoft Foundry", 0) != [
        "Validate Foundry output or fallback"
    ]:
        errors.append("successful Foundry output must be validated")
    if targets(connections, "Call Microsoft Foundry", 1) != [
        "Build sanitized Foundry fallback"
    ]:
        errors.append("Foundry errors must create a sanitized fallback")

    validation_code = nodes.get("Validate Foundry output or fallback", {}).get(
        "parameters", {}
    ).get("jsCode", "")
    for fragment in (
        "choices?.[0]?.message?.content",
        "confidence_score",
        "verification_status",
        "auto_alert_eligible",
        "model_output_invalid",
        "evidence_ids",
        "provider_metadata:source.provider_metadata",
    ):
        if fragment not in validation_code:
            errors.append(f"Foundry output validator is missing {fragment}")

    fallback_code = nodes.get("Build sanitized Foundry fallback", {}).get(
        "parameters", {}
    ).get("jsCode", "")
    for fragment in (
        "provider_authentication_failed",
        "provider_rate_limited",
        "provider_content_filtered",
        "foundry_unavailable",
        "validation_status:'fallback'",
    ):
        if fragment not in fallback_code:
            errors.append(f"Foundry failure path is missing {fragment}")
    if "persistence:{...$json" in fallback_code or "error:source" in fallback_code:
        errors.append("Foundry failure path must not persist raw provider errors")

    persist = nodes.get("Persist Foundry analysis", {}).get("parameters", {})
    if "persist_claim_analysis_result" not in persist.get("query", ""):
        errors.append("WF-41 must persist through the provider-aware database function")
    if "JSON.stringify($json.persistence)" not in persist.get("options", {}).get(
        "queryReplacement", ""
    ):
        errors.append("WF-41 must bind one JSON persistence envelope")

    if profile.get("endpoint_contract", {}).get("chat_completions_path") not in build_code:
        errors.append("WF-41 endpoint path differs from the Foundry provider profile")

    for fragment in (
        "CREATE TABLE IF NOT EXISTS analysis_provider_configs",
        "get_enabled_microsoft_foundry_config",
        "enabled = false",
        ".(openai\\.azure\\.com|services\\.ai\\.azure\\.com)",
        "012_foundry_provider_configuration",
    ):
        if fragment not in migration:
            errors.append(f"Foundry configuration migration is missing {fragment}")

    for fragment in (
        "Foundry configuration must be seeded disabled",
        "unsafe Foundry endpoint was accepted",
        "Foundry endpoint lookalike was accepted",
        "secret-bearing column",
        "ROLLBACK;",
    ):
        if fragment not in runtime_test:
            errors.append(f"Foundry configuration runtime test is missing {fragment}")

    if errors:
        print("Foundry workflow contract validation failed:", file=sys.stderr)
        for error in errors:
            print(f"- {error}", file=sys.stderr)
        return 1

    print("Foundry workflow contract validation passed (config, request, fallback, persistence).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
