"""Validate the sanitized WF-62 Teams Workflows Adaptive Card contract."""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
WORKFLOW_FILE = ROOT / "n8n" / "workflows" / "wf-62-dispatch-teams-workflows.json"
ESCAPING_FIXTURE_FILE = (
    ROOT / "fixtures" / "notifications" / "teams-markdown.synthetic.json"
)


def targets(connections: dict, node_name: str, output: int = 0) -> list[str]:
    outputs = connections.get(node_name, {}).get("main", [])
    if len(outputs) <= output:
        return []
    return [item["node"] for item in outputs[output]]


def safe_teams_text(value: str, maximum: int = 300) -> str:
    """Mirror WF-62 control-character, Markdown, and mention neutralization."""
    cleaned = re.sub(r"[\x00-\x1f\x7f]+", " ", str(value))
    cleaned = re.sub(r"\s+", " ", cleaned).strip()[:maximum]
    cleaned = cleaned.replace("\\", "\\\\")
    cleaned = re.sub(r"([*_{}\[\]()#+\-.!|~])", r"\\\1", cleaned)
    cleaned = cleaned.replace("<", "‹").replace(">", "›")
    return cleaned or "Non renseigné"


def main() -> int:
    errors: list[str] = []
    workflow = json.loads(WORKFLOW_FILE.read_text(encoding="utf-8"))
    escaping_fixture = json.loads(ESCAPING_FIXTURE_FILE.read_text(encoding="utf-8"))
    nodes = {node.get("name"): node for node in workflow.get("nodes", [])}
    connections = workflow.get("connections", {})

    expected_nodes = {
        "Run Teams dispatch manually",
        "Run Teams dispatch every minute",
        "Claim Teams jobs",
        "Build safe Adaptive Card",
        "Send Teams Adaptive Card",
        "Build Teams success result",
        "Build sanitized Teams failure",
        "Persist Teams delivery result",
    }
    missing = sorted(expected_nodes - nodes.keys())
    if missing:
        errors.append(f"WF-62 is missing nodes: {', '.join(missing)}")
    if workflow.get("active") is not False:
        errors.append("committed WF-62 export must remain inactive")
    if any("credentials" in node for node in workflow.get("nodes", [])):
        errors.append("committed WF-62 export must not contain credential identifiers")

    claim_query = nodes.get("Claim Teams jobs", {}).get("parameters", {}).get(
        "query", ""
    )
    if "claim_notification_jobs('teams', 10, 120)" not in claim_query:
        errors.append("WF-62 must claim bounded Teams jobs with a two-minute lease")

    card_code = nodes.get("Build safe Adaptive Card", {}).get("parameters", {}).get(
        "jsCode", ""
    )
    for fragment in (
        "contract_version !== 'notification-v1'",
        "channel !== 'teams'",
        "replace(/[\\u0000-\\u001f\\u007f]+/g,' ')",
        "replace(/([*_{}\\[\\]()#+\\-.!|~])/g,'\\\\$1')",
        "replace(/</g,'‹')",
        "replace(/>/g,'›')",
        "$schema:'http://adaptivecards.io/schemas/adaptive-card.json'",
        "type:'AdaptiveCard'",
        "version:'1.2'",
        "type:'FactSet'",
        "contentType:'application/vnd.microsoft.card.adaptive'",
        "contentUrl:null",
        "type:'message'",
        "disclaimer",
        "alert_id",
    ):
        if fragment not in card_code:
            errors.append(f"Teams Adaptive Card builder is missing {fragment}")
    for forbidden in (
        "Action.",
        "type:'Image'",
        "msteams",
        "raw_payload",
        "base_url",
        "contentUrl:$json",
    ):
        if forbidden.lower() in card_code.lower():
            errors.append(f"Teams Adaptive Card builder contains forbidden content: {forbidden}")

    call = nodes.get("Send Teams Adaptive Card", {})
    parameters = call.get("parameters", {})
    placeholder_url = (
        "https://teams-workflow.example.invalid/triggers/manual/paths/invoke"
        "?api-version=1&sp=%2Ftriggers%2Fmanual%2Frun&sv=1.0"
    )
    if parameters.get("method") != "POST":
        errors.append("WF-62 Teams Workflows request must use POST")
    if parameters.get("url") != placeholder_url:
        errors.append("committed WF-62 must contain only the inert placeholder endpoint")
    if parameters.get("authentication") != "genericCredentialType":
        errors.append("WF-62 must require an n8n generic credential")
    if parameters.get("genericAuthType") != "httpQueryAuth":
        errors.append("WF-62 must store the Teams signature in HTTP Query Auth")
    if parameters.get("body") != "={{ JSON.stringify($json.teams_body) }}":
        errors.append("WF-62 must serialize the Adaptive Card envelope as JSON")
    if parameters.get("options", {}).get("timeout") != 10000:
        errors.append("WF-62 Teams timeout must remain ten seconds")
    if call.get("retryOnFail"):
        errors.append("WF-62 HTTP node must not retry outside the durable outbox")
    if call.get("onError") != "continueErrorOutput":
        errors.append("WF-62 Teams failures must use the dedicated error output")
    if targets(connections, "Send Teams Adaptive Card", 0) != [
        "Build Teams success result"
    ]:
        errors.append("successful Teams calls must build a success result")
    if targets(connections, "Send Teams Adaptive Card", 1) != [
        "Build sanitized Teams failure"
    ]:
        errors.append("failed Teams calls must use the sanitized failure path")

    success_code = nodes.get("Build Teams success result", {}).get(
        "parameters", {}
    ).get("jsCode", "")
    for fragment in (
        "succeeded:true",
        "response_excerpt:'teams workflow accepted'",
        "error_code:null",
    ):
        if fragment not in success_code:
            errors.append(f"Teams success path is missing {fragment}")

    failure_code = nodes.get("Build sanitized Teams failure", {}).get(
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
            errors.append(f"Teams failure path is missing {fragment}")
    if "response_excerpt:detail" in failure_code or "error:$json" in failure_code:
        errors.append("Teams failure path must not persist a raw transport error")

    persist = nodes.get("Persist Teams delivery result", {}).get("parameters", {})
    if "record_notification_delivery_result_envelope" not in persist.get("query", ""):
        errors.append("WF-62 must finalize through the transactional result envelope")
    if "JSON.stringify($json.delivery_result)" not in persist.get("options", {}).get(
        "queryReplacement", ""
    ):
        errors.append("WF-62 must bind one JSON delivery-result envelope")
    if targets(connections, "Build Teams success result") != [
        "Persist Teams delivery result"
    ] or targets(connections, "Build sanitized Teams failure") != [
        "Persist Teams delivery result"
    ]:
        errors.append("both Teams outcomes must persist exactly once")

    for case in escaping_fixture.get("cases", []):
        actual = safe_teams_text(case.get("input", ""))
        if actual != case.get("expected"):
            errors.append(
                f"Teams escaping fixture {case.get('name')} produced {actual!r}, "
                f"expected {case.get('expected')!r}"
            )

    serialized = json.dumps(workflow).lower()
    for forbidden in (
        "logic.azure.com",
        "api.powerplatform.com",
        "prod-00.",
        "sig=",
        "authorization: bearer",
        "hooks.office.com",
    ):
        if forbidden in serialized:
            errors.append(f"committed WF-62 contains forbidden material: {forbidden}")

    if errors:
        print("Teams Workflows contract validation failed:", file=sys.stderr)
        for error in errors:
            print(f"- {error}", file=sys.stderr)
        return 1

    print("Teams Workflows Adaptive Card contract validation passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
