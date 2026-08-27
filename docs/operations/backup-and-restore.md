# Backup and restore

This M6 procedure preserves the two PostgreSQL databases and the non-secret portion of the n8n data volume. It is intended for local V1 recovery and for a repeatable restoration exercise in a clean isolated Compose project.

The backup contains operational data and encrypted n8n credentials. Treat the whole directory as sensitive even though the n8n configuration file and `.env` are excluded.

## What is preserved

- `threat_claim_monitor`: sources, monitored organizations, collection history, observations, claims, matches, analyses, notification outbox, and delivery attempts;
- `n8n`: users, projects, workflows, workflow versions, encrypted credentials, and execution metadata retained by n8n;
- the n8n data volume except `/home/node/.n8n/config`;
- migration versions, bounded application row counts, file sizes, and SHA-256 checksums in `manifest.json`.

The original `N8N_ENCRYPTION_KEY` is deliberately not copied. Store it separately in an approved password manager. Restoring the database with another key makes existing n8n credentials unreadable.

## Create a backup

macOS or Linux:

```sh
sh scripts/backup.sh backups
```

If `POSTGRES_USER` differs from `tcm_admin`, pass it as the second argument. To
target another Compose project, pass its name as the third argument.

Windows:

Run from the repository root while PostgreSQL is healthy:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/backup.ps1 `
  -DestinationDirectory backups
```

The script briefly stops n8n to keep its database and volume consistent, creates a timestamped directory, verifies the files, removes bounded container-side temporary files, and restarts n8n if it was initially running.

Expected files:

```text
backups/tcm-backup-YYYYMMDDTHHMMSSZ/
├── manifest.json
├── threat_claim_monitor.dump
├── n8n.dump
└── n8n-data.tar.gz
```

The `backups/` directory is ignored by Git. This is not encryption: copy the completed backup to protected storage and never commit, email, or attach it to an issue or pull request.

On Windows, if `POSTGRES_USER` differs from `tcm_admin`, pass `-PostgresUser`. To target another Compose project, pass `-ComposeProjectName`.

## Restore only into an isolated project first

Never use the first restoration exercise to overwrite the active development stack. Initialize a clean isolated Compose project using the same `.env` and therefore the original `N8N_ENCRYPTION_KEY`:

```powershell
docker compose -p tcm-restore-test up -d postgres
```

Restore the selected backup. Both confirmation switches are mandatory because the operation replaces the two target databases:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/restore.ps1 `
  -BackupDirectory backups/tcm-backup-YYYYMMDDTHHMMSSZ `
  -ComposeProjectName tcm-restore-test `
  -ConfirmReplaceTargetDatabases `
  -ConfirmOriginalEncryptionKey
```

The restore verifies every checksum before changing PostgreSQL. It then stops n8n if necessary, terminates connections to the two target databases, restores both custom-format dumps, restores the non-secret n8n volume archive, and compares the restored migration list and application row counts with the manifest.

The final line must be:

```text
Backup restore and manifest verification passed.
```

Before starting the restored n8n copy, disable every active workflow in the isolated database. This preserves the restored workflows while preventing collectors, analysis jobs, or notification producers from running automatically during the exercise:

```powershell
docker compose -p tcm-restore-test exec -T postgres `
  psql --username tcm_admin --dbname n8n `
  --command "UPDATE workflow_entity SET active = false WHERE active = true;"
```

This command is intentionally scoped to `tcm-restore-test`; never run it against the active project. Then start n8n on a non-conflicting host port:

```powershell
$env:N8N_PORT = '25678'
docker compose -p tcm-restore-test up -d n8n
```

Check that the expected workflows and projects are visible at <http://localhost:25678>, that saved credentials are present without exposing their values, and that application counts match the manifest. The restored workflow activation state has deliberately been changed only in this disposable copy. Do not execute collectors or notification workflows during the restore exercise.

## Recovery-time evidence

Record these values without including secrets or database contents:

- backup start and completion time;
- restore start and completion time;
- backup directory size;
- PostgreSQL and n8n health after restoration;
- manifest verification result;
- presence of expected sanitized workflows;
- any manual recovery step.

The recovery time measured on a development workstation is evidence for this environment, not a production recovery-time objective.

### Validated Windows exercise

The complete procedure was exercised successfully on Windows 11 on 20 August 2026 with PostgreSQL 17.10. The backup contained four manifest-tracked files totaling 5,020,433 bytes. Both databases and the non-secret n8n volume were restored into the isolated `tcm-restore-test` project; checksums, migration history, and application row counts matched. Six restored active workflows were disabled before n8n startup. The existing account, workflows, and `PostgreSQL - Threat Claim Monitor` credential were present, both services were healthy, and no workflow executed automatically. Backup creation through restored-interface verification completed within approximately 14 minutes including operator checks.

## Failure behavior

- A missing file, unsupported manifest, or checksum mismatch stops before database replacement.
- Missing confirmation switches stop before database replacement.
- A database or row-count mismatch fails closed.
- If a partial restore occurs after replacement begins, n8n remains stopped. Correct the cause and repeat the complete restore from the same verified backup.
- An incomplete backup directory must not be used.
- The scripts never copy `.env` or print an encryption key or database password.

## Remove the isolated exercise

After reviewing the exact project name and recording sanitized evidence, remove only the isolated test project:

```powershell
docker compose -p tcm-restore-test down --volumes
```

This command permanently removes the isolated test volumes. It must never be run without `-p tcm-restore-test`, and it must never target the active `threat-claim-monitor` project.
