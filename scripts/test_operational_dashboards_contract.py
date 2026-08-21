#!/usr/bin/env python3
"""Validate read-only operational dashboard views and the WF-71 export."""

from __future__ import annotations

import json
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MIGRATION = (ROOT / "db/migrations/025_operational_dashboards.sql").read_text(
    encoding="utf-8"
)
RUNTIME_TEST = (ROOT / "scripts/test_operational_dashboards_contract.sql").read_text(
    encoding="utf-8"
)
WORKFLOW = json.loads(
    (ROOT / "n8n/workflows/wf-71-operational-dashboards.json").read_text(
        encoding="utf-8"
    )
)


def main() -> int:
    errors: list[str] = []

    for fragment in (
        "CREATE OR REPLACE VIEW operational_source_dashboard",
        "FROM source_health AS health",
        "latest_collection_failed",
        "collection_overdue",
        "CREATE OR REPLACE VIEW operational_notification_dashboard",
        "FROM notification_channel_configs AS config",
        "expired_lease_count",
        "dead_letter_count",
        "CREATE OR REPLACE VIEW operational_dashboard_summary",
        "source_attention_count",
        "channel_attention_count",
        "025_operational_dashboards",
    ):
        if fragment not in MIGRATION:
            errors.append(f"operational dashboard migration is missing: {fragment}")

    lowered_migration = MIGRATION.lower()
    for forbidden in (
        "delete from",
        "update notification_outbox",
        "update sources",
        "payload jsonb",
        "last_error text",
        "lease_token uuid",
    ):
        if forbidden in lowered_migration:
            errors.append(f"operational dashboards are not read-only or bounded: {forbidden}")

    for fragment in (
        "source operational dashboard classification is invalid",
        "notification operational dashboard aggregation is invalid",
        "operational dashboard summary is incomplete",
        "operational dashboards expose unsafe detail",
        "ROLLBACK;",
        "Operational dashboards runtime validation passed.",
    ):
        if fragment not in RUNTIME_TEST:
            errors.append(f"operational dashboard runtime test is missing: {fragment}")

    nodes = {node.get("name"): node for node in WORKFLOW.get("nodes", [])}
    expected_nodes = {
        "Refresh dashboards manually",
        "Load operational summary",
        "Load source dashboard",
        "Load channel dashboard",
    }
    if set(nodes) != expected_nodes:
        errors.append("WF-71 must contain only the four reviewed read-only nodes")
    if WORKFLOW.get("active") is not False:
        errors.append("committed WF-71 export must remain inactive")
    if any("credentials" in node for node in WORKFLOW.get("nodes", [])):
        errors.append("committed WF-71 export must not contain credential identifiers")

    expected_queries = {
        "Load operational summary": "SELECT * FROM operational_dashboard_summary;",
        "Load source dashboard": "SELECT * FROM operational_source_dashboard ORDER BY slug;",
        "Load channel dashboard": "SELECT * FROM operational_notification_dashboard ORDER BY channel;",
    }
    for name, expected_query in expected_queries.items():
        actual_query = nodes.get(name, {}).get("parameters", {}).get("query")
        if actual_query != expected_query:
            errors.append(f"WF-71 query is not the reviewed read-only query: {name}")

    serialized_workflow = json.dumps(WORKFLOW).lower()
    for forbidden in (
        "insert ", "update ", "delete ", "http://", "https://",
        "secret", "token", "password", "payload", "last_error",
    ):
        if forbidden in serialized_workflow:
            errors.append(f"WF-71 contains mutation or unsafe detail: {forbidden}")

    if errors:
        print("Operational dashboards contract validation failed:", file=sys.stderr)
        for error in errors:
            print(f"- {error}", file=sys.stderr)
        return 1

    print("Operational dashboards contract validation passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
