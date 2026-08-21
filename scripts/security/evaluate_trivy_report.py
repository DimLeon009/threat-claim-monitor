#!/usr/bin/env python3
"""Summarize a Trivy JSON report and reject CRITICAL vulnerabilities."""

from __future__ import annotations

import json
import sys
from collections import Counter
from datetime import date
from pathlib import Path


SEVERITIES = ("UNKNOWN", "LOW", "MEDIUM", "HIGH", "CRITICAL")


def fail(message: str) -> None:
    raise SystemExit(message)


def main() -> None:
    if len(sys.argv) not in (2, 3):
        fail("Usage: evaluate_trivy_report.py REPORT.json [EXCEPTIONS.json]")

    report_path = Path(sys.argv[1])
    if not report_path.is_file():
        fail(f"Trivy report not found: {report_path}")

    try:
        report = json.loads(report_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        fail(f"Trivy report is unreadable: {exc}")

    if not isinstance(report, dict) or not isinstance(report.get("Results", []), list):
        fail("Trivy report has an unsupported structure")

    artifact_name = str(report.get("ArtifactName", ""))
    if not artifact_name:
        fail("Trivy report does not identify the scanned artifact")

    exceptions: list[dict[str, object]] = []
    if len(sys.argv) == 3:
        exception_path = Path(sys.argv[2])
        try:
            exception_contract = json.loads(exception_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as exc:
            fail(f"Trivy exception contract is unreadable: {exc}")
        if not isinstance(exception_contract, dict) \
                or exception_contract.get("contract_version") != "tcm-trivy-exceptions-v1" \
                or not isinstance(exception_contract.get("exceptions"), list):
            fail("Trivy exception contract has an unsupported structure")
        exceptions = [
            item for item in exception_contract["exceptions"]
            if isinstance(item, dict) and item.get("image") == artifact_name
        ]

    counts: Counter[str] = Counter()
    critical_findings: list[dict[str, str]] = []
    for result in report.get("Results", []):
        if not isinstance(result, dict):
            fail("Trivy result entry is not an object")
        vulnerabilities = result.get("Vulnerabilities") or []
        if not isinstance(vulnerabilities, list):
            fail("Trivy vulnerabilities entry is not an array")
        for vulnerability in vulnerabilities:
            if not isinstance(vulnerability, dict):
                fail("Trivy vulnerability entry is not an object")
            severity = str(vulnerability.get("Severity", "UNKNOWN")).upper()
            if severity not in SEVERITIES:
                severity = "UNKNOWN"
            counts[severity] += 1
            if severity == "CRITICAL":
                critical_findings.append({
                    "vulnerability_id": str(vulnerability.get("VulnerabilityID", "unknown"))[:100],
                    "target": str(result.get("Target", "unknown"))[:300],
                    "package": str(vulnerability.get("PkgName", "unknown"))[:100],
                    "installed_version": str(vulnerability.get("InstalledVersion", "unknown"))[:100],
                    "fixed_version": str(vulnerability.get("FixedVersion", "unavailable"))[:100],
                })

    print("Trivy vulnerability summary:")
    for severity in SEVERITIES:
        print(f"  {severity}: {counts[severity]}")

    accepted_finding_indexes: set[int] = set()
    used_exception_indexes: set[int] = set()
    required_exception_keys = {
        "image", "vulnerability_id", "target", "package", "installed_version",
        "expires_on", "decision", "review_owner", "rationale", "references",
    }
    for exception_index, exception in enumerate(exceptions):
        if set(exception) != required_exception_keys:
            fail("Trivy exception contains missing or unexpected fields")
        if exception["decision"] != "not_affected":
            fail("Only a reviewed not_affected decision can bypass the CRITICAL gate")
        if not all(isinstance(exception[key], str) and exception[key] for key in (
            "review_owner", "rationale", "expires_on"
        )):
            fail("Trivy exception review metadata is incomplete")
        if not isinstance(exception["references"], list) or len(exception["references"]) < 2 \
                or not all(isinstance(item, str) and item.startswith("https://")
                           for item in exception["references"]):
            fail("Trivy exception requires at least two HTTPS references")
        try:
            expires_on = date.fromisoformat(str(exception["expires_on"]))
        except ValueError:
            fail("Trivy exception expiry is invalid")
        if expires_on < date.today():
            fail(f"Trivy exception expired on {expires_on.isoformat()}")

        for finding_index, finding in enumerate(critical_findings):
            if all(exception[key] == finding[key] for key in (
                "vulnerability_id", "target", "package", "installed_version"
            )):
                accepted_finding_indexes.add(finding_index)
                used_exception_indexes.add(exception_index)
                print(
                    "Accepted reviewed not-affected exception: "
                    f"{finding['vulnerability_id']} target={finding['target']} "
                    f"expires={expires_on.isoformat()}"
                )
                break

    if len(used_exception_indexes) != len(exceptions):
        fail("Trivy exception is stale or does not exactly match the current image finding")

    blocking_findings = [
        finding for index, finding in enumerate(critical_findings)
        if index not in accepted_finding_indexes
    ]
    if blocking_findings:
        print("CRITICAL findings (bounded to 20):")
        for finding in blocking_findings[:20]:
            print(
                f"  {finding['vulnerability_id']} | {finding['package']} | "
                f"installed={finding['installed_version']} | fixed={finding['fixed_version']}"
            )
        fail(f"Container security threshold failed: {len(blocking_findings)} CRITICAL finding(s)")

    print(
        "Container security threshold passed: "
        f"{len(critical_findings)} CRITICAL finding(s), "
        f"{len(accepted_finding_indexes)} exact reviewed exception(s)."
    )


if __name__ == "__main__":
    main()
