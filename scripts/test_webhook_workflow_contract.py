"""Validate the sanitized WF-60 generic-webhook workflow contract."""

from __future__ import annotations

import json
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
WORKFLOW_FILE = ROOT / "n8n" / "workflows" / "wf-60-dispatch-generic-webhook.json"
FIXTURE_FILE = ROOT / "fixtures" / "notifications" / "webhook-payload.synthetic.json"
MIGRATION_FILE = ROOT / "db" / "migrations" / "016_webhook_delivery_envelope.sql"


def targets(connections: dict, node_name: str, output: int = 0) -> list[str]:
    outputs = connections.get(node_name, {}).get("main", [])
    if len(outputs) <= output:
        return []
    return [item["node"] for item in outputs[output]]


def main() -> int:
    errors: list[str] = []
    workflow = json.loads(WORKFLOW_FILE.read_text(encoding="utf-8"))
    fixture = json.loads(FIXTURE_FILE.read_text(encoding="utf-8"))
    migration = MIGRATION_FILE.read_text(encoding="utf-8")
    nodes = {node.get("name"): node for node in workflow.get("nodes", [])}
    connections = workflow.get("connections", {})

    expected_nodes = {
        "Run webhook dispatch manually",
        "Run webhook dispatch every minute",
        "Claim webhook jobs",
        "Build webhook request",
        "Send generic webhook",
        "Build webhook success result",
        "Build sanitized webhook failure",
        "Persist webhook delivery result",
    }
    missing = sorted(expected_nodes - nodes.keys())
    if missing:
        errors.append(f"WF-60 is missing nodes: {', '.join(missing)}")
    if workflow.get("active") is not False:
        errors.append("committed WF-60 export must remain inactive")
    if any("credentials" in node for node in workflow.get("nodes", [])):
        errors.append("committed WF-60 export must not contain credential identifiers")

    claim_query = nodes.get("Claim webhook jobs", {}).get("parameters", {}).get(
        "query", ""
    )
    if "claim_notification_jobs('webhook', 10, 120)" not in claim_query:
        errors.append("WF-60 must claim bounded webhook jobs with a two-minute lease")

    build_code = nodes.get("Build webhook request", {}).get("parameters", {}).get(
        "jsCode", ""
    )
    for fragment in (
        "contract_version !== 'notification-v1'",
        "channel !== 'webhook'",
        "notification_id:$json.notification_id",
        "lease_token:$json.lease_token",
        "webhook_body:$json.payload",
    ):
        if fragment not in build_code:
            errors.append(f"webhook request builder is missing {fragment}")

    call = nodes.get("Send generic webhook", {})
    parameters = call.get("parameters", {})
    if parameters.get("method") != "POST":
        errors.append("WF-60 generic webhook must use POST")
    if parameters.get("url") != "https://webhook.example.invalid/threat-claim-monitor":
        errors.append("committed WF-60 must contain only the inert placeholder endpoint")
    if parameters.get("authentication") != "genericCredentialType":
        errors.append("WF-60 must require an n8n generic credential")
    if parameters.get("genericAuthType") != "httpHeaderAuth":
        errors.append("WF-60 must use an HTTP Header Auth credential")
    if parameters.get("body") != "={{ JSON.stringify($json.webhook_body) }}":
        errors.append("WF-60 must serialize the common payload as JSON")
    if parameters.get("options", {}).get("timeout") != 10000:
        errors.append("WF-60 webhook timeout must remain ten seconds")
    if call.get("retryOnFail"):
        errors.append("WF-60 HTTP node must not retry outside the durable outbox")
    if call.get("onError") != "continueErrorOutput":
        errors.append("WF-60 webhook failures must use the dedicated error output")
    if targets(connections, "Send generic webhook", 0) != [
        "Build webhook success result"
    ]:
        errors.append("successful webhook calls must build a success result")
    if targets(connections, "Send generic webhook", 1) != [
        "Build sanitized webhook failure"
    ]:
        errors.append("failed webhook calls must use the sanitized failure path")

    success_code = nodes.get("Build webhook success result", {}).get(
        "parameters", {}
    ).get("jsCode", "")
    for fragment in (
        "succeeded:true",
        "[redacted unsafe response]",
        ".slice(0,500)",
        "error_code:null",
    ):
        if fragment not in success_code:
            errors.append(f"webhook success path is missing {fragment}")

    failure_code = nodes.get("Build sanitized webhook failure", {}).get(
        "parameters", {}
    ).get("jsCode", "")
    for fragment in (
        "succeeded:false",
        "delivery_rejected",
        "rate_limited",
        "http_4xx",
        "http_5xx",
        "timeout",
        "credential_unavailable",
        "response_excerpt:null",
    ):
        if fragment not in failure_code:
            errors.append(f"webhook failure path is missing {fragment}")
    if "error:$json" in failure_code or "response_excerpt:detail" in failure_code:
        errors.append("webhook failure path must not persist a raw transport error")

    persist = nodes.get("Persist webhook delivery result", {}).get("parameters", {})
    if "record_notification_delivery_result_envelope" not in persist.get("query", ""):
        errors.append("WF-60 must finalize through the transactional result envelope")
    if "JSON.stringify($json.delivery_result)" not in persist.get("options", {}).get(
        "queryReplacement", ""
    ):
        errors.append("WF-60 must bind one JSON delivery-result envelope")
    if targets(connections, "Build webhook success result") != [
        "Persist webhook delivery result"
    ] or targets(connections, "Build sanitized webhook failure") != [
        "Persist webhook delivery result"
    ]:
        errors.append("both webhook outcomes must persist exactly once")

    for fragment in (
        "FUNCTION record_notification_delivery_result_envelope",
        "invalid notification delivery result envelope",
        "record_notification_delivery_result(",
        "016_webhook_delivery_envelope",
    ):
        if fragment not in migration:
            errors.append(f"webhook delivery migration is missing {fragment}")

    encoded_fixture = json.dumps(fixture, ensure_ascii=False)
    decoded_fixture = json.loads(encoded_fixture)
    if decoded_fixture != fixture:
        errors.append("synthetic webhook fixture does not survive JSON round-trip")
    if decoded_fixture.get("contract_version") != "notification-v1":
        errors.append("synthetic webhook fixture uses the wrong contract version")
    if "\" & < > '" not in encoded_fixture:
        errors.append("synthetic webhook fixture lacks escaping-oriented characters")

    serialized_workflow = json.dumps(workflow).lower()
    for forbidden in (
        "hooks.slack.com",
        "hooks.office.com",
        "webhook.site",
        "authorization: bearer",
        "api-key",
    ):
        if forbidden in serialized_workflow:
            errors.append(f"committed WF-60 contains forbidden material: {forbidden}")

    if errors:
        print("Generic webhook workflow contract validation failed:", file=sys.stderr)
        for error in errors:
            print(f"- {error}", file=sys.stderr)
        return 1

    print("Generic webhook workflow contract validation passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
