#!/usr/bin/env python3
"""Validate the isolated Windows clean-install runtime test contract."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
RUNNER = (ROOT / "scripts" / "test_windows_installation.ps1").read_text(encoding="utf-8")
WINDOWS = (ROOT / "docs" / "development" / "windows.md").read_text(encoding="utf-8")
GETTING_STARTED = (ROOT / "docs" / "operations" / "getting-started.md").read_text(
    encoding="utf-8"
)
VALIDATE_PS = (ROOT / "scripts" / "validate.ps1").read_text(encoding="utf-8")
VALIDATE_SH = (ROOT / "scripts" / "validate.sh").read_text(encoding="utf-8")


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(message)


def main() -> None:
    required_runner_fragments = (
        '"tcm-win-install-$PID-',
        "--project-name $projectName",
        "'up', '-d', '--wait'",
        "SELECT count(*) FROM schema_migrations",
        "SELECT count(*) FROM pg_database",
        "SELECT count(*) FROM sources",
        "n8n', '--version'",
        "'5678/tcp'",
        "'127.0.0.1'",
        "'5432/tcp'",
        "for ($attempt = 1; $attempt -le 15; $attempt++)",
        "curl.exe --fail --silent --max-time 5",
        "Start-Sleep -Seconds 2",
        "/healthz",
        "to_regclass('public.workflow_entity') IS NOT NULL",
        "to_regclass('public.execution_entity') IS NOT NULL",
        "SELECT count(*) FROM workflow_entity",
        "SELECT count(*) FROM execution_entity",
        "down --volumes --remove-orphans",
        "Windows clean-install runtime validation passed.",
    )
    for fragment in required_runner_fragments:
        require(fragment in RUNNER, f"Windows installation runner is missing: {fragment}")

    require("threat-claim-monitor down --volumes" not in RUNNER,
            "Windows installation runner may target the primary Compose project")
    require("POSTGRES_PASSWORD" not in RUNNER and "N8N_ENCRYPTION_KEY" not in RUNNER,
            "Windows installation runner must not embed or print secret values")
    require("test_windows_installation_contract.py" in VALIDATE_PS,
            "Windows validation omits the installation-test contract")
    require("test_windows_installation_contract.py" in VALIDATE_SH,
            "Unix/CI validation omits the installation-test contract")

    command = (
        "powershell -NoProfile -ExecutionPolicy Bypass "
        "-File scripts/test_windows_installation.ps1"
    )
    require(command in WINDOWS, "Windows guide omits the isolated installation command")
    require(command in GETTING_STARTED,
            "Getting-started guide omits the isolated installation command")

    print("Windows clean-install contract validation passed.")


if __name__ == "__main__":
    main()
