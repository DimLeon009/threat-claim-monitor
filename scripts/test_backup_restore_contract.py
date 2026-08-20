#!/usr/bin/env python3
"""Validate the M6 backup and restore safety contract."""

from __future__ import annotations

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
BACKUP = (ROOT / "scripts" / "backup.ps1").read_text(encoding="utf-8")
RESTORE = (ROOT / "scripts" / "restore.ps1").read_text(encoding="utf-8")
RUNBOOK = (ROOT / "docs" / "operations" / "backup-and-restore.md").read_text(encoding="utf-8")


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(message)


def main() -> None:
    for database in ("threat_claim_monitor", "n8n"):
        require(database in BACKUP, f"Backup omits database {database}")
        require(database in RESTORE, f"Restore omits database {database}")

    for fragment in (
        "pg_dump",
        "--format', 'custom",
        "n8n-data.tar.gz",
        "--exclude=./config",
        "tcm-backup-v1",
        "Get-FileHash",
        "schema_migrations",
        "application_row_counts",
        "original_encryption_key_required",
        "backup_duration_seconds",
        "Backup duration:",
        "stop', 'n8n",
    ):
        require(fragment in BACKUP, f"Backup safety contract is missing: {fragment}")

    for fragment in (
        "ConfirmReplaceTargetDatabases",
        "ConfirmOriginalEncryptionKey",
        "checksum mismatch",
        "pg_terminate_backend",
        "pg_restore",
        "--clean",
        "--if-exists",
        "--exit-on-error",
        "Restored migration history",
        "Restored row count mismatch",
        "n8n remains stopped",
        "Restore duration:",
    ):
        require(fragment in RESTORE, f"Restore safety contract is missing: {fragment}")

    require("ComposeProjectName" in BACKUP and "ComposeProjectName" in RESTORE,
            "Isolated Compose project support is required")
    require(".env" not in "\n".join(
        line for line in BACKUP.splitlines() if "copy" in line.lower()
    ), "Backup must never copy .env")

    for forbidden in ("N8N_ENCRYPTION_KEY=", "POSTGRES_PASSWORD=", "api-key", "sig="):
        require(forbidden not in BACKUP, f"Backup script contains secret-like material: {forbidden}")
        require(forbidden not in RESTORE, f"Restore script contains secret-like material: {forbidden}")

    for phrase in (
        "clean isolated Compose project",
        "original `N8N_ENCRYPTION_KEY`",
        "never commit",
        "partial restore",
        "recovery time",
        "UPDATE workflow_entity SET active = false",
    ):
        require(phrase.lower() in RUNBOOK.lower(), f"Backup runbook is missing: {phrase}")

    gitignore = (ROOT / ".gitignore").read_text(encoding="utf-8")
    require("backups/" in gitignore, "Backup directory must remain ignored by Git")

    print("Backup and restore contract validation passed.")


if __name__ == "__main__":
    main()
