"""Validate contract parity between WF-40 Ollama and WF-41 Microsoft Foundry."""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
OLLAMA_WORKFLOW = ROOT / "n8n/workflows/wf-40-local-analysis.json"
FOUNDRY_WORKFLOW = ROOT / "n8n/workflows/wf-41-microsoft-foundry-analysis.json"
SCHEMA_FILE = ROOT / "ai/schemas/claim-analysis-v1.schema.json"
PROVIDER_RUNTIME_TEST = ROOT / "scripts/test_provider_aware_analysis.sql"


def node_code(workflow: dict, node_name: str) -> str:
    for node in workflow.get("nodes", []):
        if node.get("name") == node_name:
            return node.get("parameters", {}).get("jsCode", "")
    return ""


def extract(code: str, pattern: str, label: str, errors: list[str]) -> str:
    match = re.search(pattern, code, re.DOTALL)
    if not match:
        errors.append(f"could not extract {label}")
        return ""
    return match.group(1)


def normalize_user_prompt(prompt: str) -> str:
    return prompt.replace(
        "Respecte strictement ce schéma JSON, également transmis au paramètre Ollama format :",
        "Respecte strictement ce schéma JSON :",
    )


def main() -> int:
    errors: list[str] = []
    ollama = json.loads(OLLAMA_WORKFLOW.read_text(encoding="utf-8"))
    foundry = json.loads(FOUNDRY_WORKFLOW.read_text(encoding="utf-8"))
    schema = json.loads(SCHEMA_FILE.read_text(encoding="utf-8"))
    runtime_test = PROVIDER_RUNTIME_TEST.read_text(encoding="utf-8")

    ollama_build = node_code(ollama, "Build Ollama request")
    foundry_build = node_code(foundry, "Build Foundry request")
    ollama_validate = node_code(ollama, "Validate output or fallback")
    foundry_validate = node_code(foundry, "Validate Foundry output or fallback")

    schema_pattern = r"const schema = (\{.*?\});\nconst systemPrompt ="
    system_pattern = r"const systemPrompt = `(.*?)`;\nconst evidenceJson"
    user_pattern = r"const userPrompt = `(.*?)`;\n(?:const provider_metadata|return)"

    embedded_ollama_schema = extract(
        ollama_build, schema_pattern, "Ollama embedded schema", errors
    )
    embedded_foundry_schema = extract(
        foundry_build, schema_pattern, "Foundry embedded schema", errors
    )
    if embedded_ollama_schema != embedded_foundry_schema:
        errors.append("Ollama and Foundry embed different output schemas")

    ollama_system = extract(ollama_build, system_pattern, "Ollama system prompt", errors)
    foundry_system = extract(foundry_build, system_pattern, "Foundry system prompt", errors)
    if ollama_system != foundry_system:
        errors.append("Ollama and Foundry use different system safety prompts")

    ollama_user = normalize_user_prompt(
        extract(ollama_build, user_pattern, "Ollama user prompt", errors)
    )
    foundry_user = normalize_user_prompt(
        extract(foundry_build, user_pattern, "Foundry user prompt", errors)
    )
    if ollama_user != foundry_user:
        errors.append("Ollama and Foundry use different evidence prompt contracts")

    required_output_keys = set(schema.get("required", []))
    expected_output_keys = {
        "language",
        "summary_fr",
        "observed_facts",
        "uncertainties",
        "disclaimer",
    }
    if required_output_keys != expected_output_keys:
        errors.append("shared claim-analysis schema required keys drifted")

    validator_fragments = (
        "Object.keys(payload).sort().join(',')",
        "['disclaimer','language','observed_facts','summary_fr','uncertainties']",
        "payload.language !== 'fr'",
        "payload.disclaimer !== DISCLAIMER",
        "payload.summary_fr.length > 600",
        "payload.observed_facts.length > 5",
        "payload.uncertainties.length > 5",
        "fact.statement_fr.length > 240",
        "fact.evidence_ids.length > 10",
        "new Set(fact.evidence_ids).size",
        "new Set(payload.uncertainties).size",
        "!allowed.has(id)",
        "forbidden.test(value)",
        "validation_status:valid?'valid':'fallback'",
    )
    for fragment in validator_fragments:
        if fragment not in ollama_validate:
            errors.append(f"Ollama validator is missing shared rule {fragment}")
        if fragment not in foundry_validate:
            errors.append(f"Foundry validator is missing shared rule {fragment}")

    forbidden_pattern = r"const forbidden = (/.+?/i);"
    ollama_forbidden = extract(
        ollama_validate, forbidden_pattern, "Ollama forbidden-output pattern", errors
    )
    foundry_forbidden = extract(
        foundry_validate, forbidden_pattern, "Foundry forbidden-output pattern", errors
    )
    if ollama_forbidden != foundry_forbidden:
        errors.append("Ollama and Foundry reject different control-plane output")

    for workflow_name, workflow in (("Ollama", ollama), ("Foundry", foundry)):
        serialized = json.dumps(workflow, ensure_ascii=False)
        for fragment in (
            "claim-analysis-v1",
            "UNTRUSTED_EVIDENCE",
            "JSON.stringify($json.input_payload)",
            "persist_claim_analysis_result",
            "JSON.stringify($json.persistence)",
        ):
            if fragment not in serialized:
                errors.append(f"{workflow_name} workflow is missing shared contract {fragment}")

    for fragment in (
        "local_job.input_hash IS DISTINCT FROM cloud_job.input_hash",
        "provider queues must expose the same bounded input independently",
        "Ollama persistence incorrectly consumed the Foundry queue",
        "Foundry persistence must be idempotent per deployment",
        "stored multi-provider provenance is incomplete or unsafe",
        "ROLLBACK;",
    ):
        if fragment not in runtime_test:
            errors.append(f"provider-aware runtime parity test is missing {fragment}")

    if errors:
        print("Inference parity validation failed:", file=sys.stderr)
        for error in errors:
            print(f"- {error}", file=sys.stderr)
        return 1

    print(
        "Inference parity validation passed "
        "(bounded input, prompts, schema, semantics, persistence)."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
