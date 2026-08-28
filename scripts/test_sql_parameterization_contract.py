#!/usr/bin/env python3
"""Validate the reviewed SQL boundary for committed n8n workflows and migrations."""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
WORKFLOW_DIRECTORY = ROOT / "n8n" / "workflows"
MIGRATION_DIRECTORY = ROOT / "db" / "migrations"

CONSTANT_QUERIES = {
    "wf-00-orchestrator.json": {
        "Check local analysis selected",
        "Check Foundry analysis selected",
        "Check ransomware.live enabled",
        "Check RansomLook enabled",
        "Check FrenchBreaches due",
    },
    "wf-40-local-analysis.json": {"Load pending analysis jobs"},
    "wf-41-microsoft-foundry-analysis.json": {"Load configured Foundry jobs"},
    "wf-50-build-notification-outbox.json": {"Create durable notification jobs"},
    "wf-60-dispatch-generic-webhook.json": {"Claim webhook jobs"},
    "wf-61-dispatch-smtp-email.json": {"Claim email jobs"},
    "wf-62-dispatch-teams-workflows.json": {"Claim Teams jobs"},
    "wf-70-configurable-retention.json": {
        "Preview configured retention",
        "Apply configured retention",
    },
    "wf-71-operational-dashboards.json": {
        "Load operational summary",
        "Load source dashboard",
        "Load channel dashboard",
    },
}

PARAMETERIZED_QUERIES = {
    "wf-10-collect-ransomware-live.json": {
        "Insert observations if new",
        "Correlate collection observations",
        "Record sanitized correlation failure",
        "Record sanitized failure",
    },
    "wf-11-collect-ransomlook.json": {
        "Insert observations if new",
        "Correlate collection observations",
        "Record sanitized correlation failure",
        "Record sanitized failure",
    },
    "wf-12-collect-frenchbreaches.json": {
        "Insert observations if new",
        "Correlate collection observations",
        "Record sanitized correlation failure",
        "Record sanitized failure",
    },
    "wf-40-local-analysis.json": {"Persist analysis result"},
    "wf-41-microsoft-foundry-analysis.json": {"Persist Foundry analysis"},
    "wf-60-dispatch-generic-webhook.json": {"Persist webhook delivery result"},
    "wf-61-dispatch-smtp-email.json": {"Persist email delivery result"},
    "wf-62-dispatch-teams-workflows.json": {"Persist Teams delivery result"},
}

PLACEHOLDER = re.compile(r"\$([1-9][0-9]*)")
SQL_EXPRESSION_MARKERS = ("{{", "$json", "$(")
DYNAMIC_SQL = re.compile(r"\bEXECUTE\b|\bquote_ident\s*\(|\bquote_literal\s*\(", re.I)


def reviewed_inventory() -> dict[tuple[str, str], str]:
    inventory: dict[tuple[str, str], str] = {}
    for filename, names in CONSTANT_QUERIES.items():
        inventory.update({(filename, name): "constant" for name in names})
    for filename, names in PARAMETERIZED_QUERIES.items():
        inventory.update({(filename, name): "parameterized" for name in names})
    return inventory


def main() -> int:
    errors: list[str] = []
    expected = reviewed_inventory()
    observed: dict[tuple[str, str], str] = {}

    for path in sorted(WORKFLOW_DIRECTORY.glob("*.json")):
        workflow = json.loads(path.read_text(encoding="utf-8"))
        for node in workflow.get("nodes", []):
            parameters = node.get("parameters", {})
            if node.get("type") != "n8n-nodes-base.postgres":
                continue
            if parameters.get("operation") != "executeQuery":
                errors.append(f"{path.name}/{node.get('name')}: unreviewed PostgreSQL operation")
                continue

            name = node.get("name", "<unnamed>")
            key = (path.name, name)
            query = parameters.get("query")
            options = parameters.get("options", {})
            replacement = options.get("queryReplacement")
            if not isinstance(query, str) or not query.strip():
                errors.append(f"{path.name}/{name}: SQL query must be a non-empty string")
                continue

            if any(marker in query for marker in SQL_EXPRESSION_MARKERS):
                errors.append(f"{path.name}/{name}: expression interpolation is forbidden in SQL text")

            placeholder_numbers = sorted({int(value) for value in PLACEHOLDER.findall(query)})
            kind = "parameterized" if replacement else "constant"
            observed[key] = kind

            if kind == "parameterized":
                if not isinstance(replacement, str) or not replacement.startswith("={{"):
                    errors.append(f"{path.name}/{name}: Query Parameters must use an n8n expression")
                if placeholder_numbers != list(range(1, max(placeholder_numbers, default=0) + 1)):
                    errors.append(f"{path.name}/{name}: SQL placeholders must be contiguous from $1")
                if not placeholder_numbers:
                    errors.append(f"{path.name}/{name}: Query Parameters are unused")
                if options.get("queryBatching") != "single":
                    errors.append(f"{path.name}/{name}: parameterized query must use single batching")
            elif placeholder_numbers:
                errors.append(f"{path.name}/{name}: positional placeholder has no Query Parameters value")

    missing = sorted(set(expected) - set(observed))
    unexpected = sorted(set(observed) - set(expected))
    changed = sorted(key for key in set(expected) & set(observed) if expected[key] != observed[key])
    errors.extend(f"reviewed PostgreSQL node is missing: {filename}/{name}" for filename, name in missing)
    errors.extend(f"new PostgreSQL node requires review: {filename}/{name}" for filename, name in unexpected)
    errors.extend(
        f"PostgreSQL node changed from {expected[key]} to {observed[key]}: {key[0]}/{key[1]}"
        for key in changed
    )

    for path in sorted(MIGRATION_DIRECTORY.glob("*.sql")):
        sql = path.read_text(encoding="utf-8")
        if DYNAMIC_SQL.search(sql):
            errors.append(f"{path.name}: dynamic SQL construction requires dedicated review")

    if errors:
        print("SQL parameterization contract validation failed:", file=sys.stderr)
        for error in errors:
            print(f"- {error}", file=sys.stderr)
        return 1

    constant_count = sum(kind == "constant" for kind in observed.values())
    parameterized_count = sum(kind == "parameterized" for kind in observed.values())
    print(
        "SQL parameterization contract validation passed "
        f"({constant_count} constant, {parameterized_count} parameterized PostgreSQL nodes)."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
