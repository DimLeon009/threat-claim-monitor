#!/usr/bin/env python3
"""Validate the repository secret and container scanning contract."""

from __future__ import annotations

import json
import subprocess
import sys
import tempfile
from datetime import date, timedelta
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = (ROOT / ".github" / "workflows" / "security.yml").read_text(encoding="utf-8")
SECRET_PS = (ROOT / "scripts" / "security" / "scan-secrets.ps1").read_text(encoding="utf-8")
SECRET_SH = (ROOT / "scripts" / "security" / "scan-secrets.sh").read_text(encoding="utf-8")
CONTAINER_PS = (ROOT / "scripts" / "security" / "scan-containers.ps1").read_text(encoding="utf-8")
CONTAINER_SH = (ROOT / "scripts" / "security" / "scan-containers.sh").read_text(encoding="utf-8")
EVALUATOR = ROOT / "scripts" / "security" / "evaluate_trivy_report.py"
EXCEPTIONS = ROOT / "security" / "trivy-exceptions.json"
COMPOSE = (ROOT / "docker-compose.yml").read_text(encoding="utf-8")

GITLEAKS = (
    "ghcr.io/gitleaks/gitleaks:v8.30.1@"
    "sha256:c00b6bd0aeb3071cbcb79009cb16a60dd9e0a7c60e2be9ab65d25e6bc8abbb7f"
)
TRIVY = (
    "ghcr.io/aquasecurity/trivy:0.74.0@"
    "sha256:62b1e65e8869bc4b4c6aa4fa2b21595256c7c2f6018a9d9ad61caf87187c1969"
)
CHECKOUT = "actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1"
UPLOAD = "actions/upload-artifact@b7c566a772e6b6bfb58ed0dc250532a479d7789f"


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(message)


def run_evaluator(
    vulnerabilities: list[dict[str, str]],
    exceptions: list[dict[str, object]] | None = None,
) -> subprocess.CompletedProcess[str]:
    report = {
        "ArtifactName": "synthetic:image",
        "Results": [{"Target": "synthetic", "Vulnerabilities": vulnerabilities}],
    }
    with tempfile.TemporaryDirectory() as temp_directory:
        path = Path(temp_directory) / "report.json"
        path.write_text(json.dumps(report), encoding="utf-8")
        command = [sys.executable, str(EVALUATOR), str(path)]
        if exceptions is not None:
            exception_path = Path(temp_directory) / "exceptions.json"
            exception_path.write_text(json.dumps({
                "contract_version": "tcm-trivy-exceptions-v1",
                "exceptions": exceptions,
            }), encoding="utf-8")
            command.append(str(exception_path))
        return subprocess.run(
            command,
            check=False,
            capture_output=True,
            text=True,
        )


def main() -> None:
    for content in (WORKFLOW, SECRET_PS, SECRET_SH):
        require(GITLEAKS in content, "Gitleaks image is not version-and-digest pinned")
        require("--redact=100" in content, "Gitleaks output is not fully redacted")
        require("--log-opts=--all" in content, "Gitleaks does not scan complete history")

    for content in (WORKFLOW, CONTAINER_PS, CONTAINER_SH):
        require(TRIVY in content, "Trivy image is not version-and-digest pinned")
        require("postgres:17.10-alpine3.23" in content, "Pinned PostgreSQL image is not scanned")
        require("docker.n8n.io/n8nio/n8n:2.36.7" in content, "Pinned n8n image is not scanned")
        require("evaluate_trivy_report.py" in content, "CRITICAL threshold evaluator is not invoked")
        require("/var/run/docker.sock:/var/run/docker.sock" in content,
                "Trivy cannot inspect images already present in the Docker engine")
        require("--skip-version-check" in content, "Trivy version notices are not suppressed")

    require(CHECKOUT in WORKFLOW, "Checkout action is not commit pinned")
    require(UPLOAD in WORKFLOW, "Artifact action is not commit pinned")
    require("fetch-depth: 0" in WORKFLOW, "CI secret scan lacks complete Git history")
    require("if: always()" in WORKFLOW, "Trivy report is lost when threshold enforcement fails")
    require("retention-days: 14" in WORKFLOW, "Security report retention is not bounded")
    require("permissions:\n  contents: read" in WORKFLOW, "Security workflow permissions are not read-only")
    require("@master" not in WORKFLOW and "@latest" not in WORKFLOW,
            "Security workflow uses a mutable action reference")

    clean = run_evaluator([{"Severity": "HIGH", "VulnerabilityID": "CVE-SYNTHETIC-HIGH"}])
    require(clean.returncode == 0, "HIGH-only synthetic report should not fail the release threshold")
    critical = run_evaluator([{
        "Severity": "CRITICAL",
        "VulnerabilityID": "CVE-SYNTHETIC-CRITICAL",
        "PkgName": "synthetic-package",
        "InstalledVersion": "1.0",
        "FixedVersion": "1.1",
    }])
    require(critical.returncode != 0, "CRITICAL synthetic report did not fail closed")
    require("CRITICAL" in critical.stdout + critical.stderr, "Critical failure is not explainable")

    future_expiry = (date.today() + timedelta(days=30)).isoformat()
    exact_exception = {
        "image": "synthetic:image",
        "vulnerability_id": "CVE-SYNTHETIC-CRITICAL",
        "target": "synthetic",
        "package": "synthetic-package",
        "installed_version": "1.0",
        "expires_on": future_expiry,
        "decision": "not_affected",
        "review_owner": "synthetic reviewer",
        "rationale": "Synthetic call-graph review confirms the affected path is unreachable.",
        "references": ["https://example.invalid/advisory", "https://example.invalid/review"],
    }
    accepted = run_evaluator([{
        "Severity": "CRITICAL",
        "VulnerabilityID": "CVE-SYNTHETIC-CRITICAL",
        "PkgName": "synthetic-package",
        "InstalledVersion": "1.0",
    }], [exact_exception])
    require(accepted.returncode == 0, "Exact unexpired not-affected exception was not honored")

    expired_exception = dict(exact_exception)
    expired_exception["expires_on"] = (date.today() - timedelta(days=1)).isoformat()
    expired = run_evaluator([{
        "Severity": "CRITICAL",
        "VulnerabilityID": "CVE-SYNTHETIC-CRITICAL",
        "PkgName": "synthetic-package",
        "InstalledVersion": "1.0",
    }], [expired_exception])
    require(expired.returncode != 0, "Expired exception did not fail closed")

    stale_exception = dict(exact_exception)
    stale_exception["installed_version"] = "0.9"
    stale = run_evaluator([{
        "Severity": "CRITICAL",
        "VulnerabilityID": "CVE-SYNTHETIC-CRITICAL",
        "PkgName": "synthetic-package",
        "InstalledVersion": "1.0",
    }], [stale_exception])
    require(stale.returncode != 0, "Stale exception did not fail closed")

    exception_contract = json.loads(EXCEPTIONS.read_text(encoding="utf-8"))
    require(exception_contract.get("contract_version") == "tcm-trivy-exceptions-v1",
            "Trivy exception contract version is invalid")
    require(len(exception_contract.get("exceptions", [])) == 1,
            "Unexpected number of reviewed Trivy exceptions")
    postgres_exception = exception_contract["exceptions"][0]
    require(postgres_exception.get("image") == "postgres:17.10-alpine3.23",
            "Reviewed exception is not image-specific")
    require(postgres_exception.get("vulnerability_id") == "CVE-2025-68121",
            "Reviewed exception is not vulnerability-specific")
    require(postgres_exception.get("target") == "usr/local/bin/gosu",
            "Reviewed exception is not binary-specific")

    gitignore = (ROOT / ".gitignore").read_text(encoding="utf-8")
    require("security-reports/" in gitignore, "Local vulnerability reports must remain outside Git")

    for setting in (
        'N8N_DIAGNOSTICS_ENABLED: "false"',
        'N8N_PUBLIC_API_DISABLED: "true"',
        'N8N_TEMPLATES_ENABLED: "false"',
        'N8N_COMMUNITY_PACKAGES_ENABLED: "false"',
        'N8N_UNVERIFIED_PACKAGES_ENABLED: "false"',
        'N8N_PYTHON_ENABLED: "false"',
    ):
        require(setting in COMPOSE, f"Missing n8n runtime hardening setting: {setting}")

    print("Security scanning contract validation passed.")


if __name__ == "__main__":
    main()
