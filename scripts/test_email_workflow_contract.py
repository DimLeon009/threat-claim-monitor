"""Validate the sanitized WF-61 SMTP-email workflow contract."""

from __future__ import annotations

import html
import json
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
WORKFLOW_FILE = ROOT / "n8n" / "workflows" / "wf-61-dispatch-smtp-email.json"
FIXTURE_FILE = ROOT / "fixtures" / "notifications" / "webhook-payload.synthetic.json"


def targets(connections: dict, node_name: str, output: int = 0) -> list[str]:
    outputs = connections.get(node_name, {}).get("main", [])
    if len(outputs) <= output:
        return []
    return [item["node"] for item in outputs[output]]


def main() -> int:
    errors: list[str] = []
    workflow = json.loads(WORKFLOW_FILE.read_text(encoding="utf-8"))
    fixture = json.loads(FIXTURE_FILE.read_text(encoding="utf-8"))
    nodes = {node.get("name"): node for node in workflow.get("nodes", [])}
    connections = workflow.get("connections", {})

    expected_nodes = {
        "Run email dispatch manually",
        "Run email dispatch every minute",
        "Claim email jobs",
        "Render safe email",
        "Send SMTP email",
        "Build email success result",
        "Build sanitized email failure",
        "Persist email delivery result",
    }
    missing = sorted(expected_nodes - nodes.keys())
    if missing:
        errors.append(f"WF-61 is missing nodes: {', '.join(missing)}")
    if workflow.get("active") is not False:
        errors.append("committed WF-61 export must remain inactive")
    if any("credentials" in node for node in workflow.get("nodes", [])):
        errors.append("committed WF-61 export must not contain credential identifiers")

    claim_query = nodes.get("Claim email jobs", {}).get("parameters", {}).get(
        "query", ""
    )
    if "claim_notification_jobs('email', 10, 120)" not in claim_query:
        errors.append("WF-61 must claim bounded email jobs with a two-minute lease")

    render_code = nodes.get("Render safe email", {}).get("parameters", {}).get(
        "jsCode", ""
    )
    for fragment in (
        "contract_version !== 'notification-v1'",
        "channel !== 'email'",
        "replace(/[\\u0000-\\u001f\\u007f]+/g,' ')",
        "replace(/&/g,'&amp;')",
        "replace(/</g,'&lt;')",
        "replace(/>/g,'&gt;')",
        """replace(/"/g,'&quot;')""",
        "replace(/'/g,'&#39;')",
        ".slice(0,6000)",
        ".slice(0,10000)",
        "email_subject",
        "email_text",
        "email_html",
        "disclaimer",
        "alert_id",
    ):
        if fragment not in render_code:
            errors.append(f"safe email renderer is missing {fragment}")
    for forbidden in ("href=", "src=", "raw_payload", "base_url"):
        if forbidden in render_code.lower():
            errors.append(f"safe email renderer contains forbidden content: {forbidden}")

    send = nodes.get("Send SMTP email", {})
    parameters = send.get("parameters", {})
    expected_parameters = {
        "resource": "email",
        "operation": "send",
        "fromEmail": "Threat Claim Monitor <alerts@example.invalid>",
        "toEmail": "security@example.invalid",
        "subject": "={{ $json.email_subject }}",
        "emailFormat": "both",
        "text": "={{ $json.email_text }}",
        "html": "={{ $json.email_html }}",
    }
    for key, expected in expected_parameters.items():
        if parameters.get(key) != expected:
            errors.append(f"WF-61 SMTP parameter {key} differs from its safe contract")
    options = parameters.get("options", {})
    if options.get("appendAttribution") is not False:
        errors.append("WF-61 must disable external n8n attribution links")
    if options.get("allowUnauthorizedCerts") is not False:
        errors.append("WF-61 must require valid SMTP TLS certificates")
    if send.get("type") != "n8n-nodes-base.emailSend" or send.get("typeVersion") != 2.1:
        errors.append("WF-61 must use the installed Send Email node v2.1")
    if send.get("retryOnFail"):
        errors.append("WF-61 SMTP node must not retry outside the durable outbox")
    if send.get("onError") != "continueErrorOutput":
        errors.append("WF-61 SMTP failures must use the dedicated error output")
    if targets(connections, "Send SMTP email", 0) != ["Build email success result"]:
        errors.append("successful SMTP calls must build a success result")
    if targets(connections, "Send SMTP email", 1) != [
        "Build sanitized email failure"
    ]:
        errors.append("failed SMTP calls must use the sanitized failure path")

    success_code = nodes.get("Build email success result", {}).get(
        "parameters", {}
    ).get("jsCode", "")
    for fragment in (
        "succeeded:true",
        "response_status:null",
        "response_excerpt:'smtp accepted'",
        "error_code:null",
    ):
        if fragment not in success_code:
            errors.append(f"email success path is missing {fragment}")

    failure_code = nodes.get("Build sanitized email failure", {}).get(
        "parameters", {}
    ).get("jsCode", "")
    for fragment in (
        "succeeded:false",
        "connection_failed",
        "credential_unavailable",
        "timeout",
        "delivery_rejected",
        "response_excerpt:null",
    ):
        if fragment not in failure_code:
            errors.append(f"email failure path is missing {fragment}")
    if "response_excerpt:detail" in failure_code or "error:$json" in failure_code:
        errors.append("email failure path must not persist a raw SMTP error")

    persist = nodes.get("Persist email delivery result", {}).get("parameters", {})
    if "record_notification_delivery_result_envelope" not in persist.get("query", ""):
        errors.append("WF-61 must finalize through the transactional result envelope")
    if "JSON.stringify($json.delivery_result)" not in persist.get("options", {}).get(
        "queryReplacement", ""
    ):
        errors.append("WF-61 must bind one JSON delivery-result envelope")
    if targets(connections, "Build email success result") != [
        "Persist email delivery result"
    ] or targets(connections, "Build sanitized email failure") != [
        "Persist email delivery result"
    ]:
        errors.append("both email outcomes must persist exactly once")

    organization_name = fixture["organization"]["name"]
    escaped_name = html.escape(organization_name, quote=True)
    if "<France>" not in organization_name or "&lt;France&gt;" not in escaped_name:
        errors.append("email fixture does not exercise HTML escaping")
    if organization_name in escaped_name:
        errors.append("HTML escaping test retained the raw organization name")
    fact = fixture["analysis"]["observed_facts"][0]["statement_fr"]
    escaped_fact = html.escape(fact, quote=True)
    for escaped_marker in ("&quot;", "&amp;", "&lt;", "&gt;", "&#x27;"):
        if escaped_marker not in escaped_fact:
            errors.append(f"email escaping fixture is missing {escaped_marker}")

    serialized = json.dumps(workflow).lower()
    for forbidden in ("smtp.example.com", "@digitregroup.com", "password", "api-key"):
        if forbidden in serialized:
            errors.append(f"committed WF-61 contains forbidden material: {forbidden}")

    if errors:
        print("SMTP email workflow contract validation failed:", file=sys.stderr)
        for error in errors:
            print(f"- {error}", file=sys.stderr)
        return 1

    print("SMTP email workflow contract validation passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
