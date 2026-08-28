#!/usr/bin/env python3
"""Validate the repository-safe M6 synthetic demonstration contract."""

from __future__ import annotations

import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
DEMO_DIR = ROOT / "scripts" / "demo"
WORKFLOW_PATH = ROOT / "n8n" / "workflows" / "wf-99-receive-synthetic-demo.json"
RUNBOOK_PATH = ROOT / "docs" / "operations" / "end-to-end-synthetic-demo.md"

EXPECTED_SCRIPTS = {
    "seed_end_to_end.sql",
    "store_deterministic_analysis.sql",
    "enqueue_webhook_notification.sql",
    "preflight_webhook_dispatch.sql",
    "verify_end_to_end.sql",
    "cleanup_end_to_end.sql",
}
FIXTURE_MARKER = "m6-end-to-end-v1"
DEMO_ORGANIZATION = "TCM Synthetic Demo Organization"


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(message)


def main() -> None:
    actual_scripts = {path.name for path in DEMO_DIR.glob("*.sql")}
    require(EXPECTED_SCRIPTS <= actual_scripts, "M6 demo SQL scripts are incomplete")

    combined = "\n".join(
        (DEMO_DIR / script).read_text(encoding="utf-8")
        for script in sorted(EXPECTED_SCRIPTS)
    )
    analysis_script = (DEMO_DIR / "store_deterministic_analysis.sql").read_text(
        encoding="utf-8"
    )
    require(
        analysis_script.isascii(),
        "Fallback demo SQL must remain ASCII-safe when piped by Windows PowerShell",
    )
    require(FIXTURE_MARKER in combined, "M6 fixture marker is missing")
    require(DEMO_ORGANIZATION in combined, "M6 synthetic organization is missing")
    require("correlate_collection_run_exact" in combined, "Demo bypasses claim correlation")
    require("persist_claim_analysis_result" in combined, "Demo bypasses analysis persistence")
    require("enqueue_claim_notifications" in combined, "Demo bypasses the outbox producer")
    require("validate_notification_payload" in combined, "Demo does not verify the notification contract")
    require("notification_attempts" in combined, "Demo does not verify delivery evidence")
    require("demo_channel_snapshot" in combined, "Demo does not restore channel switches")
    require("cleanup refused" in combined, "Demo cleanup lacks a fail-closed scope guard")

    forbidden = ("api_key", "authorization: bearer", "sig=", "password=")
    lowered = combined.lower()
    require(not any(item in lowered for item in forbidden), "Demo scripts contain secret-like material")

    workflow = json.loads(WORKFLOW_PATH.read_text(encoding="utf-8"))
    require(workflow.get("name") == "WF-99 Receive synthetic demo webhook", "Unexpected demo receiver name")
    nodes = {node["name"]: node for node in workflow.get("nodes", [])}
    required_nodes = {
        "Receive synthetic notification",
        "Validate synthetic payload",
        "Acknowledge synthetic notification",
    }
    require(required_nodes <= nodes.keys(), "Synthetic receiver nodes are incomplete")

    receiver = nodes["Receive synthetic notification"]
    params = receiver.get("parameters", {})
    require(params.get("authentication") == "headerAuth", "Synthetic receiver must require header auth")
    require(params.get("path") == "tcm-synthetic-demo", "Unexpected synthetic webhook path")
    require("credentials" not in receiver, "Workflow export must not contain credential identifiers")

    validator = nodes["Validate synthetic payload"]["parameters"]["jsCode"]
    require(DEMO_ORGANIZATION in validator, "Receiver does not reject non-demo organizations")
    require("notification-v1" in validator, "Receiver does not validate the notification contract")
    require("$json.body" in validator, "Receiver does not validate the webhook body")

    serialized = json.dumps(workflow, ensure_ascii=False).lower()
    require("webhook.example" not in serialized, "Demo receiver contains an external endpoint")
    require("http://" not in serialized and "https://" not in serialized, "Demo receiver contains a URL")

    runbook = RUNBOOK_PATH.read_text(encoding="utf-8")
    for fragment in (
        "same Header Auth credential object",
        "webhook.example.invalid",
        "notification credential is unavailable",
        "getaddrinfo ENOTFOUND webhook.example.invalid",
        "keep it unpublished",
    ):
        require(fragment in runbook, f"Demo runbook omits runtime safeguard: {fragment}")

    print("End-to-end synthetic demo contract validation passed.")


if __name__ == "__main__":
    main()
