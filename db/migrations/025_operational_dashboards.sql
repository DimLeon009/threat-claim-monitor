BEGIN;

CREATE OR REPLACE VIEW operational_source_dashboard AS
SELECT
  health.source_id,
  health.slug,
  health.name,
  health.enabled,
  health.health_status,
  CASE
    WHEN health.enabled = false THEN 'inactive'
    WHEN health.health_status = 'healthy' THEN 'ok'
    WHEN health.health_status = 'degraded'
      AND health.consecutive_failure_count >= 3 THEN 'critical'
    ELSE 'warning'
  END AS attention_level,
  CASE
    WHEN health.enabled = false THEN 'source_disabled'
    WHEN health.health_status = 'never_run' THEN 'collection_not_observed'
    WHEN health.health_status = 'degraded' THEN 'latest_collection_failed'
    WHEN health.health_status = 'stale' THEN 'collection_overdue'
    ELSE 'none'
  END AS attention_reason,
  health.latest_status,
  health.latest_started_at,
  health.latest_finished_at,
  health.last_success_at,
  health.last_failure_at,
  health.consecutive_failure_count,
  health.latest_response_validation,
  health.latest_fetched_count,
  health.latest_inserted_count,
  health.latest_contract_version,
  health.latest_failure_code,
  CASE
    WHEN health.enabled AND health.last_success_at IS NOT NULL
      THEN health.last_success_at
        + make_interval(mins => health.poll_interval_minutes)
    ELSE null
  END AS next_collection_due_at
FROM source_health AS health;

CREATE OR REPLACE VIEW operational_notification_dashboard AS
WITH outbox_metrics AS (
  SELECT
    config.channel,
    config.enabled,
    count(outbox.id)::bigint AS total_job_count,
    count(*) FILTER (WHERE outbox.status = 'pending')::bigint AS pending_count,
    count(*) FILTER (
      WHERE outbox.status IN ('pending', 'retry')
        AND outbox.available_at <= statement_timestamp()
    )::bigint AS ready_count,
    count(*) FILTER (
      WHERE outbox.status = 'retry'
        AND outbox.available_at > statement_timestamp()
    )::bigint AS scheduled_retry_count,
    count(*) FILTER (WHERE outbox.status = 'processing')::bigint AS processing_count,
    count(*) FILTER (
      WHERE outbox.status = 'processing'
        AND outbox.lease_expires_at <= statement_timestamp()
    )::bigint AS expired_lease_count,
    count(*) FILTER (
      WHERE outbox.status = 'sent'
        AND outbox.sent_at >= statement_timestamp() - interval '24 hours'
    )::bigint AS sent_last_24h_count,
    count(*) FILTER (WHERE outbox.status = 'dead_letter')::bigint AS dead_letter_count,
    min(outbox.available_at) FILTER (
      WHERE outbox.status IN ('pending', 'retry')
        AND outbox.available_at <= statement_timestamp()
    ) AS oldest_ready_at,
    max(outbox.sent_at) AS last_sent_at
  FROM notification_channel_configs AS config
  LEFT JOIN notification_outbox AS outbox
    ON outbox.channel = config.channel
  GROUP BY config.channel, config.enabled
), attempt_metrics AS (
  SELECT
    outbox.channel,
    max(attempt.attempted_at) AS last_attempt_at
  FROM notification_outbox AS outbox
  JOIN notification_attempts AS attempt
    ON attempt.notification_id = outbox.id
  GROUP BY outbox.channel
)
SELECT
  metrics.channel,
  metrics.enabled,
  CASE
    WHEN metrics.enabled = false THEN 'disabled'
    WHEN metrics.dead_letter_count > 0 OR metrics.expired_lease_count > 0 THEN 'critical'
    WHEN metrics.scheduled_retry_count > 0 THEN 'degraded'
    WHEN metrics.ready_count > 0 THEN 'backlog'
    ELSE 'healthy'
  END AS health_status,
  metrics.total_job_count,
  metrics.pending_count,
  metrics.ready_count,
  metrics.scheduled_retry_count,
  metrics.processing_count,
  metrics.expired_lease_count,
  metrics.sent_last_24h_count,
  metrics.dead_letter_count,
  metrics.oldest_ready_at,
  metrics.last_sent_at,
  attempts.last_attempt_at
FROM outbox_metrics AS metrics
LEFT JOIN attempt_metrics AS attempts
  ON attempts.channel = metrics.channel;

CREATE OR REPLACE VIEW operational_dashboard_summary AS
SELECT
  statement_timestamp() AS generated_at,
  (SELECT count(*) FROM operational_source_dashboard)::bigint AS source_count,
  (SELECT count(*) FROM operational_source_dashboard
    WHERE enabled)::bigint AS enabled_source_count,
  (SELECT count(*) FROM operational_source_dashboard
    WHERE attention_level IN ('warning', 'critical'))::bigint
    AS source_attention_count,
  (SELECT count(*) FROM operational_source_dashboard
    WHERE attention_level = 'critical')::bigint AS critical_source_count,
  (SELECT count(*) FROM operational_notification_dashboard
    WHERE enabled)::bigint AS enabled_channel_count,
  (SELECT count(*) FROM operational_notification_dashboard
    WHERE health_status IN ('backlog', 'degraded', 'critical'))::bigint
    AS channel_attention_count,
  coalesce((SELECT sum(ready_count)
    FROM operational_notification_dashboard), 0)::bigint
    AS ready_notification_count,
  coalesce((SELECT sum(dead_letter_count)
    FROM operational_notification_dashboard), 0)::bigint
    AS dead_letter_notification_count,
  coalesce((SELECT sum(expired_lease_count)
    FROM operational_notification_dashboard), 0)::bigint
    AS expired_notification_lease_count;

INSERT INTO schema_migrations (version)
VALUES ('025_operational_dashboards')
ON CONFLICT (version) DO NOTHING;

COMMIT;
