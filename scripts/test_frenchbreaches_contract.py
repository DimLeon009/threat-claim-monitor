"""Validate the minimal FrenchBreaches RSS adapter and fail-closed contract."""

from __future__ import annotations

import json
import sys
import xml.etree.ElementTree as ET
from datetime import datetime
from pathlib import Path
from urllib.parse import urlparse


ROOT = Path(__file__).resolve().parents[1]
WORKFLOW_FILE = ROOT / "n8n/workflows/wf-12-collect-frenchbreaches.json"
MIGRATION_FILE = ROOT / "db/migrations/023_frenchbreaches_rss_ingestion.sql"
FIXTURE_DIRECTORY = ROOT / "fixtures/frenchbreaches"
RUNTIME_TEST = ROOT / "scripts/test_frenchbreaches_contract.sql"
FAILURE_CODES = {"fetch_failed", "response_validation_failed", "ingestion_failed"}


def target_names(connections: dict[str, object], node_name: str, output: int) -> list[str]:
    outputs = connections.get(node_name, {}).get("main", [])
    if len(outputs) <= output:
        return []
    return [connection["node"] for connection in outputs[output]]


def parse_fixture(path: Path) -> list[dict[str, str]]:
    root = ET.parse(path).getroot()
    if root.tag != "rss" or root.attrib.get("version") != "2.0":
        return []
    records: list[dict[str, str]] = []
    for item in root.findall("./channel/item"):
        records.append(
            {
                field: (item.findtext(field) or "").strip()
                for field in ("title", "guid", "link", "pubDate")
            }
        )
    return records


def records_are_valid(records: list[dict[str, str]]) -> bool:
    if not 1 <= len(records) <= 200:
        return False
    seen: set[str] = set()
    for record in records:
        if any(not record.get(field) for field in ("title", "guid", "link", "pubDate")):
            return False
        if record["guid"] != record["link"] or record["guid"] in seen:
            return False
        parsed = urlparse(record["link"])
        if parsed.scheme != "https" or parsed.hostname != "frenchbreaches.invalid":
            return False
        try:
            datetime.strptime(record["pubDate"], "%a, %d %b %Y %H:%M:%S %Z")
        except ValueError:
            return False
        seen.add(record["guid"])
    return True


def main() -> int:
    errors: list[str] = []
    workflow = json.loads(WORKFLOW_FILE.read_text(encoding="utf-8"))
    migration = MIGRATION_FILE.read_text(encoding="utf-8")
    runtime_test = RUNTIME_TEST.read_text(encoding="utf-8")
    nodes = {node.get("name"): node for node in workflow.get("nodes", [])}
    connections = workflow.get("connections", {})

    expected_nodes = {
        "Fetch FrenchBreaches incidents",
        "Validate and allow-list RSS items",
        "Insert observations if new",
        "Correlate collection observations",
        "Record sanitized correlation failure",
        "Stop with sanitized correlation failure",
        "Classify fetch failure",
        "Classify validation failure",
        "Classify ingestion failure",
        "Record sanitized failure",
        "Stop with sanitized failure",
    }
    missing_nodes = sorted(expected_nodes - nodes.keys())
    if missing_nodes:
        errors.append(f"missing workflow nodes: {', '.join(missing_nodes)}")

    fetch = nodes.get("Fetch FrenchBreaches incidents", {})
    if fetch.get("parameters", {}).get("url") != "https://frenchbreaches.com/feed.xml":
        errors.append("RSS node must use the official incidents feed")
    if fetch.get("type") != "n8n-nodes-base.rssFeedRead":
        errors.append("fetch node must use the RSS Feed Read integration")
    if fetch.get("retryOnFail") is not True or fetch.get("maxTries") != 3:
        errors.append("RSS request must use three bounded attempts")
    if fetch.get("waitBetweenTries") != 2000:
        errors.append("RSS retry delay must remain 2000 milliseconds")

    guarded_nodes = {
        "Fetch FrenchBreaches incidents": "Classify fetch failure",
        "Validate and allow-list RSS items": "Classify validation failure",
        "Insert observations if new": "Classify ingestion failure",
    }
    for node_name, failure_target in guarded_nodes.items():
        node = nodes.get(node_name, {})
        if node.get("onError") != "continueErrorOutput":
            errors.append(f"{node_name} must use its dedicated error output")
        if target_names(connections, node_name, 1) != [failure_target]:
            errors.append(f"{node_name} error output must target {failure_target}")

    validation_code = nodes.get("Validate and allow-list RSS items", {}).get(
        "parameters", {}
    ).get("jsCode", "")
    for fragment in (
        "items.length < 1",
        "items.length > 200",
        "['title', 'guid', 'link', 'pubDate']",
        "guid !== link",
        "permalinkPattern",
        "frenchbreaches\\.com",
        "seenGuids.has(guid)",
        "parsedDate.toISOString()",
        "return { title, guid, link, published_at",
    ):
        if fragment not in validation_code:
            errors.append(f"validation code is missing contract guard: {fragment}")
    for prohibited in ("description", "content", "category", "creator"):
        if prohibited in validation_code.lower():
            errors.append(f"validation code must not retain or inspect RSS field: {prohibited}")

    classifier_codes: set[str] = set()
    for node_name in (
        "Classify fetch failure",
        "Classify validation failure",
        "Classify ingestion failure",
    ):
        code = nodes.get(node_name, {}).get("parameters", {}).get("jsCode", "")
        matched = [failure_code for failure_code in FAILURE_CODES if failure_code in code]
        if len(matched) != 1 or "error" in code.lower():
            errors.append(f"{node_name} must emit one static code without raw error data")
        else:
            classifier_codes.add(matched[0])
        if target_names(connections, node_name, 0) != ["Record sanitized failure"]:
            errors.append(f"{node_name} must target Record sanitized failure")
    if classifier_codes != FAILURE_CODES:
        errors.append("failure classifiers must cover every allow-listed code")

    if "ingest_frenchbreaches_collection" not in nodes.get(
        "Insert observations if new", {}
    ).get("parameters", {}).get("query", ""):
        errors.append("ingestion node must call ingest_frenchbreaches_collection")
    if "record_frenchbreaches_failure" not in nodes.get(
        "Record sanitized failure", {}
    ).get("parameters", {}).get("query", ""):
        errors.append("failure recorder must call record_frenchbreaches_failure")
    if target_names(connections, "Insert observations if new", 0) != [
        "Correlate collection observations"
    ]:
        errors.append("successful ingestion must target collection correlation")

    for fragment in (
        "poll_interval_minutes = 240",
        "CREATE OR REPLACE FUNCTION ingest_frenchbreaches_collection",
        "CREATE OR REPLACE FUNCTION record_frenchbreaches_failure",
        "frenchbreaches-rss-v1-2026-08-20",
        "rejected_unmatchable_count",
        "WHERE normalized_victim_name IS NOT NULL",
        "ON CONFLICT (source_id, source_key) DO NOTHING",
        "baseline_completed_at",
        "023_frenchbreaches_rss_ingestion",
    ):
        if fragment not in migration:
            errors.append(f"migration is missing required contract: {fragment}")
    for prohibited in ("description", "category", "creator", "content"):
        if f"'{prohibited}'" in migration:
            errors.append(f"migration must not persist RSS field: {prohibited}")

    valid_records = parse_fixture(FIXTURE_DIRECTORY / "incidents.synthetic.xml")
    malformed_records = parse_fixture(
        FIXTURE_DIRECTORY / "malformed-missing-guid.synthetic.xml"
    )
    if not records_are_valid(valid_records):
        errors.append("synthetic RSS fixture must satisfy the minimal contract")
    if records_are_valid(malformed_records):
        errors.append("missing-GUID fixture must fail closed")
    if not any(record["title"] == "*********" for record in valid_records):
        errors.append("fixture must cover an unmatchable title")

    fixture_text = "\n".join(
        path.read_text(encoding="utf-8")
        for path in sorted(FIXTURE_DIRECTORY.glob("*.xml"))
    ).lower()
    for prohibited in ("frenchbreaches.com", "ransomware.live", "ransomlook.io", ".onion"):
        if prohibited in fixture_text:
            errors.append(f"fixtures must not contain a live source reference: {prohibited}")

    for fragment in (
        "FrenchBreaches baseline ingestion is invalid",
        "FrenchBreaches replay is not idempotent",
        "FrenchBreaches persisted payload is not minimal",
        "ROLLBACK;",
    ):
        if fragment not in runtime_test:
            errors.append(f"runtime test is missing assertion: {fragment}")

    if workflow.get("active") is not False:
        errors.append("committed WF-12 export must remain inactive")
    if any("credentials" in node for node in workflow.get("nodes", [])):
        errors.append("committed WF-12 export must not contain credential identifiers")

    if errors:
        print("FrenchBreaches RSS contract validation failed:", file=sys.stderr)
        for error in errors:
            print(f"- {error}", file=sys.stderr)
        return 1

    print("FrenchBreaches RSS contract validation passed (minimal allow-list and failure paths).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
