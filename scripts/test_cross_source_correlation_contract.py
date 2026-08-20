"""Validate M5 cross-source correlation and notification deduplication contracts."""

from __future__ import annotations

import json
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MIGRATION = ROOT / "db/migrations/020_cross_source_correlation.sql"
UNMATCHABLE_FIX = ROOT / "db/migrations/022_skip_unmatchable_correlation_observations.sql"
WORKFLOW = ROOT / "n8n/workflows/wf-11-collect-ransomlook.json"
RUNTIME_TEST = ROOT / "scripts/test_cross_source_correlation_contract.sql"


def main() -> int:
    errors: list[str] = []
    migration = MIGRATION.read_text(encoding="utf-8")
    unmatchable_fix = UNMATCHABLE_FIX.read_text(encoding="utf-8")
    workflow = json.loads(WORKFLOW.read_text(encoding="utf-8"))
    runtime_test = RUNTIME_TEST.read_text(encoding="utf-8")
    nodes = {node.get("name"): node for node in workflow.get("nodes", [])}
    connections = workflow.get("connections", {})

    for fragment in (
        "CREATE OR REPLACE FUNCTION correlate_observation_exact",
        "count(DISTINCT linked_observation.source_id)",
        "verification_status = 'multi_source_observed'",
        "claim.verification_status = 'claimed'",
        "CREATE OR REPLACE FUNCTION correlate_collection_run_exact",
        "source.enabled = true",
        "correlation_source_slug",
        "CREATE OR REPLACE FUNCTION record_claim_correlation_failure",
        "CREATE OR REPLACE FUNCTION enqueue_ready_claim_notifications",
        "outbox.notification_type = 'new_claim'",
        "outbox.claim_id = claim.id",
        "outbox.organization_id = accepted_match.organization_id",
        "outbox.channel = channel_config.channel",
        "020_cross_source_correlation",
    ):
        if fragment not in migration:
            errors.append(f"migration is missing required contract: {fragment}")

    for node_name in (
        "Correlate collection observations",
        "Record sanitized correlation failure",
        "Stop with sanitized correlation failure",
    ):
        if node_name not in nodes:
            errors.append(f"WF-11 is missing node: {node_name}")

    for fragment in (
        "CREATE OR REPLACE FUNCTION correlate_collection_run_exact",
        "normalize_match_text(observation.victim_name) IS NULL",
        "normalize_match_text(observation.victim_name) IS NOT NULL",
        "correlation_skipped_unmatchable_count",
        "022_skip_unmatchable_correlation_observations",
    ):
        if fragment not in unmatchable_fix:
            errors.append(f"unmatchable-correlation fix is missing required contract: {fragment}")

    correlation = nodes.get("Correlate collection observations", {})
    if "correlate_collection_run_exact" not in correlation.get("parameters", {}).get("query", ""):
        errors.append("WF-11 correlation node must use correlate_collection_run_exact")
    if correlation.get("onError") != "continueErrorOutput":
        errors.append("WF-11 correlation must use its dedicated error output")

    insert_targets = connections.get("Insert observations if new", {}).get("main", [[]])[0]
    if [target.get("node") for target in insert_targets] != ["Correlate collection observations"]:
        errors.append("WF-11 successful ingestion must target correlation")

    for fragment in (
        "cross-source observations did not correlate to one claim",
        "multi-source claim state is invalid",
        "cross-source correlation replay changed claim state",
        "unmatchable observation was not skipped safely",
        "ROLLBACK;",
    ):
        if fragment not in runtime_test:
            errors.append(f"runtime test is missing required assertion: {fragment}")

    if errors:
        print("Cross-source correlation contract validation failed:", file=sys.stderr)
        for error in errors:
            print(f"- {error}", file=sys.stderr)
        return 1

    print("Cross-source correlation contract validation passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
