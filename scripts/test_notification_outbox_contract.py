"""Validate the M4 common notification and transactional outbox contract."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MIGRATION_FILE = ROOT / "db" / "migrations" / "013_notification_outbox_contract.sql"
RUNTIME_TEST_FILE = ROOT / "scripts" / "test_notification_outbox_contract.sql"


def require_fragments(content: str, fragments: tuple[str, ...], label: str) -> None:
    missing = [fragment for fragment in fragments if fragment not in content]
    if missing:
        raise AssertionError(f"{label} is missing required fragments: {missing}")


def main() -> None:
    migration = MIGRATION_FILE.read_text(encoding="utf-8")
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
        runtime_test,
        (
            "first enqueue did not create one job per enabled channel",
            "notification enqueue replay was not idempotent",
            "stored notification payload violates the common contract",
            "historical evidence created a notification job",
            "invalid notification payload was accepted",
            "notification channel configuration contains a secret-bearing column",
            "ROLLBACK;",
        ),
        "notification runtime test",
    )

    print("Notification outbox contract validation passed.")


if __name__ == "__main__":
    main()
