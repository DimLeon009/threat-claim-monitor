"""Validate the ransomware.live workflow's failure-handling contract."""

from __future__ import annotations

import json
import sys
from pathlib import Path


REPOSITORY_ROOT = Path(__file__).resolve().parent.parent
WORKFLOW_FILE = REPOSITORY_ROOT / "n8n/workflows/wf-10-collect-ransomware-live.json"
MALFORMED_ROOT = REPOSITORY_ROOT / "fixtures/ransomware-live/malformed-root.synthetic.json"
MISSING_REQUIRED = REPOSITORY_ROOT / "fixtures/ransomware-live/missing-required-field.synthetic.json"
REQUIRED_FIELDS = ("victim", "group", "discovered")
FAILURE_CODES = {
    "fetch_failed",
    "response_validation_failed",
    "ingestion_failed",
}


def load_json(path: Path) -> object:
    return json.loads(path.read_text(encoding="utf-8"))


def response_is_valid(body: object) -> bool:
    if not isinstance(body, list) or not 1 <= len(body) <= 500:
        return False
    for record in body:
        if not isinstance(record, dict):
            return False
        for field in REQUIRED_FIELDS:
            value = record.get(field)
            if not isinstance(value, str) or not value.strip():
                return False
    return True


def target_names(connections: dict[str, object], node_name: str, output: int) -> list[str]:
    outputs = connections.get(node_name, {}).get("main", [])
    if len(outputs) <= output:
        return []
    return [connection["node"] for connection in outputs[output]]


def main() -> int:
    errors: list[str] = []
    workflow = load_json(WORKFLOW_FILE)
    if not isinstance(workflow, dict):
        print("Workflow contract validation failed: workflow root must be an object", file=sys.stderr)
        return 1

    nodes = {node.get("name"): node for node in workflow.get("nodes", [])}
    connections = workflow.get("connections", {})
    expected_nodes = {
        "Fetch recent victims",
        "Validate and allow-list response",
        "Insert observations if new",
        "Classify fetch failure",
        "Classify validation failure",
        "Classify ingestion failure",
        "Record sanitized failure",
        "Stop with sanitized failure",
    }
    missing_nodes = sorted(expected_nodes - nodes.keys())
    if missing_nodes:
        errors.append(f"missing workflow nodes: {', '.join(missing_nodes)}")

    fetch = nodes.get("Fetch recent victims", {})
    fetch_options = fetch.get("parameters", {}).get("options", {})
    if fetch_options.get("timeout") != 10000:
        errors.append("HTTP timeout must remain 10000 milliseconds")
    if fetch.get("retryOnFail") is not True or fetch.get("maxTries") != 3:
        errors.append("HTTP request must use three bounded attempts")
    if fetch.get("waitBetweenTries") != 2000:
        errors.append("HTTP retry delay must remain 2000 milliseconds")

    guarded_nodes = {
        "Fetch recent victims": "Classify fetch failure",
        "Validate and allow-list response": "Classify validation failure",
        "Insert observations if new": "Classify ingestion failure",
    }
    for node_name, failure_target in guarded_nodes.items():
        node = nodes.get(node_name, {})
        if node.get("onError") != "continueErrorOutput":
            errors.append(f"{node_name} must use its dedicated error output")
        if target_names(connections, node_name, 1) != [failure_target]:
            errors.append(f"{node_name} error output must target {failure_target}")

    classifier_codes: set[str] = set()
    for node_name in (
        "Classify fetch failure",
        "Classify validation failure",
        "Classify ingestion failure",
    ):
        code = nodes.get(node_name, {}).get("parameters", {}).get("jsCode", "")
        matched = [failure_code for failure_code in FAILURE_CODES if failure_code in code]
        if len(matched) != 1 or "error" in code.lower():
            errors.append(f"{node_name} must emit one static failure code without raw error data")
        else:
            classifier_codes.add(matched[0])
        if target_names(connections, node_name, 0) != ["Record sanitized failure"]:
            errors.append(f"{node_name} must target Record sanitized failure")
    if classifier_codes != FAILURE_CODES:
        errors.append("failure classifiers must cover each allow-listed failure code exactly once")

    recorder = nodes.get("Record sanitized failure", {})
    recorder_query = recorder.get("parameters", {}).get("query", "")
    replacement = recorder.get("parameters", {}).get("options", {}).get("queryReplacement", "")
    if "record_ransomware_live_failure" not in recorder_query:
        errors.append("failure recorder must call record_ransomware_live_failure")
    if "$json.failure_code" not in replacement:
        errors.append("failure recorder must bind the classified failure code")
    if target_names(connections, "Record sanitized failure", 0) != ["Stop with sanitized failure"]:
        errors.append("failure recorder must terminate through Stop with sanitized failure")

    stop_node = nodes.get("Stop with sanitized failure", {})
    if stop_node.get("type") != "n8n-nodes-base.stopAndError":
        errors.append("failure path must end with a Stop And Error node")
    if stop_node.get("parameters", {}).get("errorMessage") != "={{ $json.error_message }}":
        errors.append("Stop And Error must use only the sanitized database message")

    validation_code = nodes.get("Validate and allow-list response", {}).get("parameters", {}).get("jsCode", "")
    for expected_fragment in (
        "Array.isArray(records)",
        "records.length < 1",
        "records.length > 500",
        "requiredStringFields",
        "Unexpected response content type",
    ):
        if expected_fragment not in validation_code:
            errors.append(f"validation code is missing contract guard: {expected_fragment}")

    if response_is_valid(load_json(MALFORMED_ROOT)):
        errors.append("malformed-root fixture must be rejected")
    if response_is_valid(load_json(MISSING_REQUIRED)):
        errors.append("missing-required-field fixture must be rejected")

    if errors:
        print("Ransomware.live workflow contract validation failed:", file=sys.stderr)
        for error in errors:
            print(f"- {error}", file=sys.stderr)
        return 1

    print("Ransomware.live workflow contract validation passed (malformed response and timeout paths).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
