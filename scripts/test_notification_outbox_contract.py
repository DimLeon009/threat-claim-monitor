"""Validate the M4 common notification and transactional outbox contract."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MIGRATION_FILE = ROOT / "db" / "migrations" / "013_notification_outbox_contract.sql"
LEASE_MIGRATION_FILE = ROOT / "db" / "migrations" / "014_notification_job_leases.sql"
DELIVERY_MIGRATION_FILE = ROOT / "db" / "migrations" / "015_notification_delivery_results.sql"
WEBHOOK_MIGRATION_FILE = ROOT / "db" / "migrations" / "016_webhook_delivery_envelope.sql"
RUNTIME_TEST_FILE = ROOT / "scripts" / "test_notification_outbox_contract.sql"


def require_fragments(content: str, fragments: tuple[str, ...], label: str) -> None:
    missing = [fragment for fragment in fragments if fragment not in content]
    if missing:
        raise AssertionError(f"{label} is missing required fragments: {missing}")


def main() -> None:
    migration = MIGRATION_FILE.read_text(encoding="utf-8")
    lease_migration = LEASE_MIGRATION_FILE.read_text(encoding="utf-8")
    delivery_migration = DELIVERY_MIGRATION_FILE.read_text(encoding="utf-8")
    webhook_migration = WEBHOOK_MIGRATION_FILE.read_text(encoding="utf-8")
    runtime_test = RUNTIME_TEST_FILE.read_text(encoding="utf-8")

    require_fragments(
        migration,
        (
            "CREATE TABLE IF NOT EXISTS notification_channel_configs",
            "('webhook', false)",
            "('email', false)",
            "('teams', false)",
            "FUNCTION validate_notification_payload",
            "'notification-v1'",
            "'alert_id'",
            "'verification_status'",
            "'confidence_score'",
            "'observed_facts'",
            "'uncertainties'",
            "'sources'",
            "Déclaration criminelle non vérifiée",
            "https?://|api[_-]?key|authorization",
            "notification_outbox_payload_contract_check",
            "FUNCTION enqueue_claim_notifications",
            "FOR UPDATE",
            "observation.is_historical = false",
            "review_status IN ('accepted', 'auto_accepted')",
            "claim has multiple accepted organization matches",
            "analysis does not cover current evidence version",
            "ON CONFLICT (deduplication_key) DO NOTHING",
            "013_notification_outbox_contract",
        ),
        "notification migration",
    )

    forbidden_delivery_fragments = (
        "CREATE EXTENSION http",
        "http_post",
        "smtp",
        "teams.microsoft.com",
        "hooks.office.com",
    )
    found_forbidden = [
        fragment for fragment in forbidden_delivery_fragments if fragment.lower() in migration.lower()
    ]
    if found_forbidden:
        raise AssertionError(
            f"outbox producer performs external delivery: {found_forbidden}"
        )

    require_fragments(
        lease_migration,
        (
            "ADD COLUMN IF NOT EXISTS lease_token uuid",
            "ADD COLUMN IF NOT EXISTS lease_expires_at timestamptz",
            "notification_outbox_processing_lease_check",
            "FUNCTION claim_notification_jobs",
            "requested_limit NOT BETWEEN 1 AND 100",
            "requested_lease_seconds NOT BETWEEN 30 AND 900",
            "status IN ('pending', 'retry')",
            "status = 'processing'",
            "lease_expires_at <= clock_timestamp()",
            "FOR UPDATE SKIP LOCKED",
            "SET status = 'processing'",
            "lease_token = gen_random_uuid()",
            "014_notification_job_leases",
        ),
        "notification lease migration",
    )

    require_fragments(
        delivery_migration,
        (
            "FUNCTION sanitize_notification_response_excerpt",
            "[redacted unsafe response]",
            "left(regexp_replace(candidate, '[[:cntrl:]]+', ' ', 'g'), 500)",
            "FUNCTION notification_delivery_error_message",
            "FUNCTION record_notification_delivery_result",
            "FOR UPDATE",
            "notification lease is not active",
            "notification lease expired",
            "max_attempts constant integer := 5",
            "least(",
            "3600",
            "status = resolved_status",
            "INSERT INTO notification_attempts",
            "FUNCTION requeue_dead_letter_notification",
            "status = 'retry'",
            "015_notification_delivery_results",
        ),
        "notification delivery-result migration",
    )

    require_fragments(
        webhook_migration,
        (
            "FUNCTION record_notification_delivery_result_envelope",
            "jsonb_typeof(candidate) <> 'object'",
            "invalid notification delivery result envelope",
            "record_notification_delivery_result(",
            "016_webhook_delivery_envelope",
        ),
        "webhook delivery envelope migration",
    )

    require_fragments(
        runtime_test,
        (
            "first enqueue did not create one job per enabled channel",
            "notification enqueue replay was not idempotent",
            "stored notification payload violates the common contract",
            "historical evidence created a notification job",
            "invalid notification payload was accepted",
            "notification channel configuration contains a secret-bearing column",
            "eligible webhook job was not leased correctly",
            "active notification lease was claimed twice",
            "expired notification lease was not safely reclaimed",
            "future retry job was claimed before available_at",
            "notification failure did not schedule the expected retry",
            "notification did not reach dead-letter after five failures",
            "notification attempt history was not sanitized",
            "dead-letter notification was not safely requeued",
            "notification success was not finalized atomically",
            "stale notification lease was accepted",
            "invalid delivery result envelope was accepted",
            "WF-50 producer did not create the expected channel jobs",
            "WF-50 producer replay returned a fully enqueued claim",
            "ROLLBACK;",
        ),
        "notification runtime test",
    )

    print("Notification outbox contract validation passed.")


if __name__ == "__main__":
    main()
