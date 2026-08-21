#!/usr/bin/env python3
"""Validate the M6 transactional failure-mode suite contract."""

from __future__ import annotations

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
POWERSHELL_RUNNER = (ROOT / "scripts" / "test_failure_modes.ps1").read_text(encoding="utf-8")
SHELL_RUNNER = (ROOT / "scripts" / "test_failure_modes.sh").read_text(encoding="utf-8")
DOCUMENTATION = (ROOT / "docs" / "operations" / "failure-mode-validation.md").read_text(
    encoding="utf-8"
)
CI = (ROOT / ".github" / "workflows" / "ci.yml").read_text(encoding="utf-8")
VALIDATE_SH = (ROOT / "scripts" / "validate.sh").read_text(encoding="utf-8")

CONTRACTS = {
    "scripts/test_cross_source_correlation_contract.sql": (
        "Cross-source correlation validation passed.",
        "correlation_skipped_unmatchable_count",
    ),
    "scripts/test_source_health_contract.sql": (
        "Source health and switches validation passed.",
        "consecutive_failure_count",
    ),
    "scripts/test_local_analysis_persistence.sql": (
        "Local-analysis persistence validation passed.",
        "deterministic fallback",
    ),
    "scripts/test_provider_aware_analysis.sql": (
        "Provider-aware analysis validation passed.",
        "provider_rate_limited",
    ),
    "scripts/test_notification_outbox_contract.sql": (
        "Notification outbox contract validation passed.",
        "dead_letter",
    ),
}


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(message)


def main() -> None:
    for relative_path, required_fragments in CONTRACTS.items():
        path = ROOT / relative_path
        require(path.is_file(), f"Missing failure-mode contract: {relative_path}")
        content = path.read_text(encoding="utf-8")
        require("BEGIN;" in content and "ROLLBACK;" in content,
                f"Failure-mode contract is not transactionally isolated: {relative_path}")
        require("COMMIT;" not in content,
                f"Failure-mode contract may persist synthetic data: {relative_path}")
        for fragment in required_fragments:
            require(fragment in content,
                    f"Failure-mode evidence is missing from {relative_path}: {fragment}")
        require(relative_path in POWERSHELL_RUNNER,
                f"Windows runner omits failure-mode contract: {relative_path}")
        require(relative_path in SHELL_RUNNER,
                f"Unix runner omits failure-mode contract: {relative_path}")
        require(relative_path in DOCUMENTATION,
                f"Failure-mode runbook omits contract: {relative_path}")

    for runner in (POWERSHELL_RUNNER, SHELL_RUNNER):
        require("ON_ERROR_STOP=on" in runner,
                "Failure-mode runner does not stop at the first PostgreSQL error")
        require("docker compose up -d --wait postgres" in runner,
                "Failure-mode runner does not require a healthy PostgreSQL service")

    for fragment in ("ReadAllBytes", "ToBase64String", "base64 -d"):
        require(fragment in POWERSHELL_RUNNER,
                f"Windows runner lacks encoding-safe SQL transport: {fragment}")

    require("run: sh scripts/validate.sh" in CI
            and "sh scripts/test_failure_modes.sh" in VALIDATE_SH,
            "CI does not execute the transactional failure-mode suite")
    require("docker compose --env-file .env.example down -v" in CI,
            "CI does not remove its ephemeral failure-mode database with explicit safe configuration")

    print("Failure-mode suite contract validation passed (5 isolated runtime scenarios).")


if __name__ == "__main__":
    main()
