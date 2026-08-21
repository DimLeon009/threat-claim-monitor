#!/usr/bin/env python3
"""Validate the conservative configurable-retention contract and WF-70 export."""

from __future__ import annotations

import json
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MIGRATION = (ROOT / "db" / "migrations" / "024_configurable_retention.sql").read_text(
    encoding="utf-8"
)
RUNTIME_TEST = (ROOT / "scripts" / "test_retention_contract.sql").read_text(
    encoding="utf-8"
)
WORKFLOW = json.loads(
    (ROOT / "n8n" / "workflows" / "wf-70-configurable-retention.json").read_text(
        encoding="utf-8"
    )
)
COMPOSE = (ROOT / "docker-compose.yml").read_text(encoding="utf-8")
ENVIRONMENT = (ROOT / ".env.example").read_text(encoding="utf-8")


def main() -> int:
    errors: list[str] = []

    for fragment in (
        "CREATE TABLE IF NOT EXISTS retention_policy",
        "enabled boolean NOT NULL DEFAULT false",
        "collection_run_retention_days BETWEEN 7 AND 3650",
        "max_collection_runs_per_job BETWEEN 1 AND 10000",
        "CREATE TABLE IF NOT EXISTS retention_runs",
        "CREATE OR REPLACE FUNCTION set_retention_policy",
        "CREATE OR REPLACE FUNCTION retention_collection_run_candidates",
        "CREATE OR REPLACE FUNCTION preview_retention_job",
        "CREATE OR REPLACE FUNCTION run_retention_job",
        "pg_try_advisory_xact_lock",
        "FOR UPDATE OF run SKIP LOCKED",
        "NOT EXISTS (\n      SELECT 1\n      FROM observations",
        "latest_success.status = 'succeeded'",
        "latest_failure.status IN ('partial', 'failed')",
        "LIMIT policy_record.max_collection_runs_per_job",
        "024_configurable_retention",
    ):
        if fragment not in MIGRATION:
            errors.append(f"retention migration is missing: {fragment}")

    for forbidden in (
        "DELETE FROM claims",
        "DELETE FROM observations",
        "DELETE FROM analyses",
        "DELETE FROM organization_matches",
        "DELETE FROM notification_outbox",
        "DELETE FROM notification_attempts",
    ):
        if forbidden.lower() in MIGRATION.lower():
            errors.append(f"retention migration crosses the V1 business-data boundary: {forbidden}")

    for fragment in (
        "retention preview did not identify the bounded safe candidates",
        "retention removed evidence, current health state, or a running collection",
        "disabled retention job changed data or audit history",
        "unsafe retention window was accepted",
        "ROLLBACK;",
        "Configurable retention runtime validation passed.",
    ):
        if fragment not in RUNTIME_TEST:
            errors.append(f"retention runtime test is missing: {fragment}")

    nodes = {node.get("name"): node for node in WORKFLOW.get("nodes", [])}
    expected_nodes = {
        "Preview retention manually",
        "Run retention daily",
        "Preview configured retention",
        "Apply configured retention",
    }
    if set(nodes) != expected_nodes:
        errors.append("WF-70 must contain only the four reviewed retention nodes")
    if WORKFLOW.get("active") is not False:
        errors.append("committed WF-70 export must remain inactive")
    if any("credentials" in node for node in WORKFLOW.get("nodes", [])):
        errors.append("committed WF-70 export must not contain credential identifiers")
    if nodes.get("Preview configured retention", {}).get("parameters", {}).get("query") \
            != "SELECT * FROM preview_retention_job();":
        errors.append("WF-70 manual path must be preview-only")
    if nodes.get("Apply configured retention", {}).get("parameters", {}).get("query") \
            != "SELECT * FROM run_retention_job();":
        errors.append("WF-70 scheduled path must call only the bounded retention function")
    schedule = nodes.get("Run retention daily", {}).get("parameters", {})
    if "15 3 * * *" not in json.dumps(schedule):
        errors.append("WF-70 must run once daily at 03:15 Europe/Paris")

    serialized_workflow = json.dumps(WORKFLOW).lower()
    for forbidden in ("http://", "https://", "secret", "token", "password"):
        if forbidden in serialized_workflow:
            errors.append(f"WF-70 contains forbidden external or secret material: {forbidden}")

    for variable in (
        "N8N_EXECUTIONS_DATA_MAX_AGE_HOURS=336",
        "N8N_EXECUTIONS_DATA_PRUNE_MAX_COUNT=10000",
    ):
        if variable not in ENVIRONMENT:
            errors.append(f"n8n retention setting is not configurable in .env.example: {variable}")
    for expression in (
        "${N8N_EXECUTIONS_DATA_MAX_AGE_HOURS:-336}",
        "${N8N_EXECUTIONS_DATA_PRUNE_MAX_COUNT:-10000}",
    ):
        if expression not in COMPOSE:
            errors.append(f"Compose does not consume configurable n8n retention: {expression}")

    if errors:
        print("Configurable retention contract validation failed:", file=sys.stderr)
        for error in errors:
            print(f"- {error}", file=sys.stderr)
        return 1

    print("Configurable retention contract validation passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
