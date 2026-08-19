"""Validate WF-50 and its bounded transactional notification producer."""

from __future__ import annotations

import json
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
WORKFLOW_FILE = ROOT / "n8n" / "workflows" / "wf-50-build-notification-outbox.json"
MIGRATION_FILE = ROOT / "db" / "migrations" / "017_notification_outbox_workflow.sql"


def main() -> int:
    errors: list[str] = []
    workflow = json.loads(WORKFLOW_FILE.read_text(encoding="utf-8"))
    migration = MIGRATION_FILE.read_text(encoding="utf-8")
    nodes = {node.get("name"): node for node in workflow.get("nodes", [])}

    expected_nodes = {
        "Build outbox manually",
        "Build outbox every minute",
        "Create durable notification jobs",
    }
    missing = sorted(expected_nodes - nodes.keys())
    if missing:
        errors.append(f"WF-50 is missing nodes: {', '.join(missing)}")
    if workflow.get("active") is not False:
        errors.append("committed WF-50 export must remain inactive")
    if any("credentials" in node for node in workflow.get("nodes", [])):
        errors.append("committed WF-50 export must not contain credential identifiers")

    query = nodes.get("Create durable notification jobs", {}).get("parameters", {}).get(
        "query", ""
    )
    if query != "SELECT * FROM enqueue_ready_claim_notifications(50);":
        errors.append("WF-50 must call only the bounded transactional producer")

    for fragment in (
        "FUNCTION enqueue_ready_claim_notifications",
        "requested_limit NOT BETWEEN 1 AND 100",
        "analysis.evidence_version = claim.evidence_version",
        "analysis.validation_status IN ('valid', 'fallback')",
        "observation.is_historical = false",
        "review_status IN ('accepted', 'auto_accepted')",
        "provider_config.enabled = true",
        "NOT EXISTS (",
        "notification-v1:%s:%s:%s:new_claim:%s",
        "enqueue_claim_notifications(",
        "017_notification_outbox_workflow",
    ):
        if fragment not in migration:
            errors.append(f"notification producer migration is missing {fragment}")

    serialized = json.dumps(workflow).lower()
    for forbidden in ("http://", "https://", "smtp", "credential", "secret", "token"):
        if forbidden in serialized:
            errors.append(f"WF-50 contains forbidden external-delivery material: {forbidden}")

    if errors:
        print("Notification producer workflow contract validation failed:", file=sys.stderr)
        for error in errors:
            print(f"- {error}", file=sys.stderr)
        return 1

    print("Notification producer workflow contract validation passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
