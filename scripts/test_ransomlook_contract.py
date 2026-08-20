"""Validate the RansomLook adapter, fixtures, and fail-closed routing contract."""

from __future__ import annotations

import json
import sys
from pathlib import Path


REPOSITORY_ROOT = Path(__file__).resolve().parent.parent
WORKFLOW_FILE = REPOSITORY_ROOT / "n8n/workflows/wf-11-collect-ransomlook.json"
MIGRATION_FILE = REPOSITORY_ROOT / "db/migrations/018_ransomlook_ingestion.sql"
UNMATCHABLE_FIX_MIGRATION = (
    REPOSITORY_ROOT / "db/migrations/019_ransomlook_unmatchable_titles.sql"
)
FIXTURE_DIRECTORY = REPOSITORY_ROOT / "fixtures/ransomlook"
REQUIRED_FIELDS = ("post_title", "group_name", "discovered")
FAILURE_CODES = {"fetch_failed", "response_validation_failed", "ingestion_failed"}


def load_json(path: Path) -> object:
    return json.loads(path.read_text(encoding="utf-8"))


def extract_records(body: object) -> list[object] | None:
    if isinstance(body, list):
        return body
    if isinstance(body, dict) and isinstance(body.get("posts"), list):
        return body["posts"]
    return None


def records_are_valid(body: object) -> bool:
    records = extract_records(body)
    if records is None or not 1 <= len(records) <= 500:
        return False
    return all(
        isinstance(record, dict)
        and all(isinstance(record.get(field), str) and record[field].strip() for field in REQUIRED_FIELDS)
        for record in records
    )


def target_names(connections: dict[str, object], node_name: str, output: int) -> list[str]:
    outputs = connections.get(node_name, {}).get("main", [])
    if len(outputs) <= output:
        return []
    return [connection["node"] for connection in outputs[output]]


def main() -> int:
    errors: list[str] = []
    workflow = load_json(WORKFLOW_FILE)
    migration = MIGRATION_FILE.read_text(encoding="utf-8")
    unmatchable_fix = UNMATCHABLE_FIX_MIGRATION.read_text(encoding="utf-8")
    nodes = {node.get("name"): node for node in workflow.get("nodes", [])}
    connections = workflow.get("connections", {})

    expected_nodes = {
        "Fetch recent posts",
        "Validate and allow-list response",
        "Insert observations if new",
        "Classify fetch failure",
        "Classify validation failure",
        "Classify ingestion failure",
        "Record sanitized failure",
        "Stop with sanitized failure",
        "Correlate collection observations",
        "Record sanitized correlation failure",
        "Stop with sanitized correlation failure",
    }
    missing_nodes = sorted(expected_nodes - nodes.keys())
    if missing_nodes:
        errors.append(f"missing workflow nodes: {', '.join(missing_nodes)}")

    fetch = nodes.get("Fetch recent posts", {})
    if fetch.get("parameters", {}).get("url") != "https://www.ransomlook.io/api/posts?days=7":
        errors.append("HTTP node must use the documented public seven-day posts endpoint")
    if fetch.get("parameters", {}).get("options", {}).get("timeout") != 10000:
        errors.append("HTTP timeout must remain 10000 milliseconds")
    if fetch.get("retryOnFail") is not True or fetch.get("maxTries") != 3:
        errors.append("HTTP request must use three bounded attempts")
    if fetch.get("waitBetweenTries") != 2000:
        errors.append("HTTP retry delay must remain 2000 milliseconds")

    guarded_nodes = {
        "Fetch recent posts": "Classify fetch failure",
        "Validate and allow-list response": "Classify validation failure",
        "Insert observations if new": "Classify ingestion failure",
    }
    for node_name, failure_target in guarded_nodes.items():
        node = nodes.get(node_name, {})
        if node.get("onError") != "continueErrorOutput":
            errors.append(f"{node_name} must use its dedicated error output")
        if target_names(connections, node_name, 1) != [failure_target]:
            errors.append(f"{node_name} error output must target {failure_target}")

    validation_code = nodes.get("Validate and allow-list response", {}).get("parameters", {}).get(
        "jsCode", ""
    )
    for fragment in (
        "Array.isArray(body)",
        "Array.isArray(body.posts)",
        "records.length < 1",
        "records.length > 500",
        "requiredStringFields",
        "Unexpected response content type",
    ):
        if fragment not in validation_code:
            errors.append(f"validation code is missing contract guard: {fragment}")

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
    if "record_ransomlook_failure" not in recorder.get("parameters", {}).get("query", ""):
        errors.append("failure recorder must call record_ransomlook_failure")
    if "$json.failure_code" not in recorder.get("parameters", {}).get("options", {}).get(
        "queryReplacement", ""
    ):
        errors.append("failure recorder must bind only the classified failure code")
    if target_names(connections, "Record sanitized failure", 0) != ["Stop with sanitized failure"]:
        errors.append("failure recorder must terminate through Stop with sanitized failure")

    insertion_query = nodes.get("Insert observations if new", {}).get("parameters", {}).get("query", "")
    if "ingest_ransomlook_collection" not in insertion_query:
        errors.append("ingestion node must call ingest_ransomlook_collection")
    if target_names(connections, "Insert observations if new", 0) != [
        "Correlate collection observations"
    ]:
        errors.append("successful RansomLook ingestion must target collection correlation")

    for required_sql in (
        "CREATE OR REPLACE FUNCTION ingest_ransomlook_collection",
        "CREATE OR REPLACE FUNCTION record_ransomlook_failure",
        "ON CONFLICT (source_id, source_key) DO NOTHING",
        "baseline_completed_at",
        "ransomlook-posts-v1-2026-08-19",
    ):
        if required_sql not in migration:
            errors.append(f"migration is missing required contract: {required_sql}")

    for required_sql in (
        "CREATE OR REPLACE FUNCTION ingest_ransomlook_collection",
        "rejected_unmatchable_count",
        "WHERE normalized_victim_name IS NOT NULL",
        "AND normalized_threat_actor IS NOT NULL",
        "RansomLook payload contains no usable observation",
    ):
        if required_sql not in unmatchable_fix:
            errors.append(f"unmatchable-title fix is missing required contract: {required_sql}")

    wrapped = load_json(FIXTURE_DIRECTORY / "posts-wrapped.synthetic.json")
    direct = load_json(FIXTURE_DIRECTORY / "posts-array.synthetic.json")
    malformed = load_json(FIXTURE_DIRECTORY / "malformed-wrapper.synthetic.json")
    if not records_are_valid(wrapped):
        errors.append("wrapped response fixture must be accepted")
    if not records_are_valid(direct):
        errors.append("direct-array compatibility fixture must be accepted")
    if records_are_valid(malformed):
        errors.append("unknown response wrapper must fail closed")
    if extract_records(wrapped) != extract_records(direct):
        errors.append("wrapped and direct fixtures must normalize to the same records")
    if not any(
        record.get("post_title") == "*********" for record in (extract_records(wrapped) or [])
    ):
        errors.append("fixtures must cover a masked title that normalizes to no usable text")

    fixture_text = "\n".join(
        path.read_text(encoding="utf-8") for path in sorted(FIXTURE_DIRECTORY.glob("*.json"))
    ).lower()
    for prohibited in ("ransomlook.io", ".onion", "http://", "https://"):
        if prohibited in fixture_text:
            errors.append(f"synthetic fixtures must not contain live or external URLs: {prohibited}")

    if errors:
        print("RansomLook workflow contract validation failed:", file=sys.stderr)
        for error in errors:
            print(f"- {error}", file=sys.stderr)
        return 1

    print("RansomLook workflow contract validation passed (array and wrapped response forms).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
