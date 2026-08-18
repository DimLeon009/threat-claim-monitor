"""Validate the provider-neutral analysis contract and Foundry profile."""

from __future__ import annotations

import json
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
PROFILE_FILE = ROOT / "ai/providers/microsoft-foundry.json"
ADR_FILE = ROOT / "docs/architecture/adr/0002-hybrid-local-foundry-inference.md"
CONTRACT_FILE = ROOT / "docs/ai/inference-providers.md"
SCHEMA_FILE = ROOT / "ai/schemas/claim-analysis-v1.schema.json"


def main() -> int:
    errors: list[str] = []
    profile = json.loads(PROFILE_FILE.read_text(encoding="utf-8"))
    schema = json.loads(SCHEMA_FILE.read_text(encoding="utf-8"))
    adr = ADR_FILE.read_text(encoding="utf-8")
    contract = CONTRACT_FILE.read_text(encoding="utf-8")

    if profile.get("provider") != "microsoft_foundry":
        errors.append("Foundry profile provider is not microsoft_foundry")
    if profile.get("api_family") != "openai-v1":
        errors.append("Foundry profile must use the stable OpenAI v1 API")

    endpoint = profile.get("endpoint_contract", {})
    if endpoint.get("scheme") != "https":
        errors.append("Foundry endpoints must require HTTPS")
    if endpoint.get("chat_completions_path") != "/openai/v1/chat/completions":
        errors.append("Foundry profile has an unexpected chat-completions path")
    if set(endpoint.get("allowed_host_suffixes", [])) != {
        ".openai.azure.com",
        ".services.ai.azure.com",
    }:
        errors.append("Foundry endpoint suffix allow-list is incomplete")

    auth = profile.get("authentication", {})
    if auth.get("preferred") != "microsoft_entra_id":
        errors.append("Microsoft Entra ID must remain the preferred authentication")
    if auth.get("secret_location") != "n8n_credential_store":
        errors.append("Foundry secrets must stay in the n8n credential store")

    runtime = profile.get("runtime", {})
    expected_runtime = {
        "stream": False,
        "temperature": 0,
        "max_completion_tokens": 512,
        "response_format": "json_schema",
    }
    for key, value in expected_runtime.items():
        if runtime.get(key) != value:
            errors.append(f"Foundry runtime has invalid {key}")

    policy = profile.get("data_policy", {})
    if policy.get("classification") != "public_metadata_only":
        errors.append("Foundry data classification must remain public_metadata_only")
    if policy.get("explicit_cloud_selection_required") is not True:
        errors.append("Foundry use must require explicit cloud selection")
    if policy.get("automatic_local_to_cloud_failover") is not False:
        errors.append("Automatic local-to-cloud failover must remain disabled")
    if policy.get("leaked_material_allowed") is not False:
        errors.append("Leaked material must never be allowed")

    serialized_profile = json.dumps(profile, ensure_ascii=False).lower()
    for forbidden in ("api_key_value", "client_secret", "subscription_id", "tenant_id"):
        if forbidden in serialized_profile:
            errors.append(f"Foundry profile contains forbidden secret/config field {forbidden}")

    required_schema_keys = {
        "language",
        "summary_fr",
        "observed_facts",
        "uncertainties",
        "disclaimer",
    }
    if set(schema.get("required", [])) != required_schema_keys:
        errors.append("Shared claim-analysis schema contract changed unexpectedly")
    if schema.get("additionalProperties") is not False:
        errors.append("Shared claim-analysis schema must reject additional properties")

    for text, label in ((adr, "ADR-0002"), (contract, "provider contract")):
        for fragment in (
            "automatic",
            "public metadata",
            "Microsoft Entra ID",
            "claim-analysis-v1",
        ):
            if fragment not in text:
                errors.append(f"{label} is missing {fragment}")

    if errors:
        print("Inference-provider contract validation failed:", file=sys.stderr)
        for error in errors:
            print(f"- {error}", file=sys.stderr)
        return 1

    print("Inference-provider contract validation passed (hybrid routing, Foundry, data policy).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
