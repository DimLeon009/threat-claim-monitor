"""Validate repository-safe source contract fixtures."""

from __future__ import annotations

import json
import sys
from pathlib import Path
from urllib.parse import urlparse


REPOSITORY_ROOT = Path(__file__).resolve().parent.parent
FIXTURE = REPOSITORY_ROOT / "fixtures/ransomware-live/recent-victims.synthetic.json"
REQUIRED_STRING_FIELDS = (
    "activity", "attackdate", "claim_url", "country", "description",
    "discovered", "domain", "group", "screenshot", "url", "victim",
)
PROHIBITED_HOST_SUFFIXES = (
    "ransomware.live", "ransomlook.io", "frenchbreaches.com",
)


def validate_url(value: str, field: str, index: int, errors: list[str]) -> None:
    if not value:
        return
    parsed = urlparse(value)
    if parsed.scheme != "https" or not parsed.hostname:
        errors.append(f"record {index}: {field} must be empty or an absolute HTTPS URL")
        return
    if any(
        parsed.hostname == suffix or parsed.hostname.endswith(f".{suffix}")
        for suffix in PROHIBITED_HOST_SUFFIXES
    ):
        errors.append(f"record {index}: {field} must not contain a live source URL")


def main() -> int:
    errors: list[str] = []
    try:
        records = json.loads(FIXTURE.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        print(f"Source fixture validation failed: {error}", file=sys.stderr)
        return 1

    if not isinstance(records, list) or not records:
        errors.append("fixture root must be a non-empty JSON array")
        records = []

    for index, record in enumerate(records, start=1):
        if not isinstance(record, dict):
            errors.append(f"record {index}: value must be an object")
            continue

        missing = sorted(set(REQUIRED_STRING_FIELDS) - record.keys())
        if missing:
            errors.append(f"record {index}: missing fields: {', '.join(missing)}")

        for field in REQUIRED_STRING_FIELDS:
            if field in record and not isinstance(record[field], str):
                errors.append(f"record {index}: {field} must be a string")

        for field in ("victim", "group", "discovered"):
            value = record.get(field)
            if not isinstance(value, str) or not value.strip():
                errors.append(f"record {index}: {field} must be a non-empty string")
        if not isinstance(record.get("infostealer"), dict):
            errors.append(f"record {index}: infostealer must be an object")

        for field in ("claim_url", "screenshot", "url"):
            value = record.get(field)
            if isinstance(value, str):
                validate_url(value, field, index, errors)

    if errors:
        print("Source fixture validation failed:", file=sys.stderr)
        for error in errors:
            print(f"- {error}", file=sys.stderr)
        return 1

    print(f"Source fixture validation passed ({len(records)} synthetic records).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
