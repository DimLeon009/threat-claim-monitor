\set ON_ERROR_STOP on

BEGIN;

UPDATE notification_channel_configs
SET enabled = CASE channel
  WHEN 'email' THEN false
  ELSE true
END,
updated_at = statement_timestamp();

CREATE TEMP TABLE dashboard_notification_baseline AS
SELECT *
FROM operational_notification_dashboard
WHERE channel = 'webhook';

INSERT INTO sources (
  id, slug, name, source_kind, base_url, enabled, poll_interval_minutes, metadata
)
VALUES (
  '7f000000-0000-4000-8000-000000000001',
  'synthetic-dashboard-source',
  'Synthetic Dashboard Source',
  'api',
  'https://dashboard.invalid',
  true,
  60,
  '{"fixture":"operational-dashboard"}'::jsonb
);

INSERT INTO collection_runs (
  id, source_id, started_at, finished_at, status,
  fetched_count, inserted_count, error_message, metadata
)
VALUES
  (
    '7f000000-0000-4000-8000-000000000011',
    '7f000000-0000-4000-8000-000000000001',
    statement_timestamp() - interval '3 hours',
    statement_timestamp() - interval '3 hours',
    'failed', 0, 0, 'synthetic sanitized failure',
    '{"failure_code":"upstream_timeout"}'::jsonb
  ),
  (
    '7f000000-0000-4000-8000-000000000012',
    '7f000000-0000-4000-8000-000000000001',
    statement_timestamp() - interval '2 hours',
    statement_timestamp() - interval '2 hours',
    'partial', 1, 0, 'synthetic sanitized failure',
    '{"failure_code":"response_validation_failed"}'::jsonb
  ),
  (
    '7f000000-0000-4000-8000-000000000013',
    '7f000000-0000-4000-8000-000000000001',
    statement_timestamp() - interval '1 hour',
    statement_timestamp() - interval '1 hour',
    'failed', 0, 0, 'synthetic sanitized failure',
    '{"failure_code":"upstream_unavailable"}'::jsonb
  );

INSERT INTO claims (
  id, canonical_key, victim_name, normalized_victim_name,
  first_seen_at, last_seen_at, evidence_version
)
VALUES (
  '7f000000-0000-4000-8000-000000000021',
  'synthetic-operational-dashboard-claim',
  'Synthetic Dashboard Victim',
  'synthetic dashboard victim',
  statement_timestamp(), statement_timestamp(), 1
);

WITH fixtures (
  id, status, attempts, available_at, sent_at, lease_token,
  lease_expires_at, last_error
) AS (
  VALUES
    (
      '7f000000-0000-4000-8000-000000000031'::uuid,
      'retry', 1, statement_timestamp() - interval '5 minutes', null::timestamptz,
      null::uuid, null::timestamptz, 'temporary delivery failure'
    ),
    (
      '7f000000-0000-4000-8000-000000000032'::uuid,
      'processing', 1, statement_timestamp() - interval '5 minutes', null::timestamptz,
      '7f000000-0000-4000-8000-000000000041'::uuid,
      statement_timestamp() - interval '1 minute', null::text
    ),
    (
      '7f000000-0000-4000-8000-000000000033'::uuid,
      'sent', 1, statement_timestamp() - interval '1 hour',
      statement_timestamp() - interval '1 hour', null::uuid, null::timestamptz, null::text
    ),
    (
      '7f000000-0000-4000-8000-000000000034'::uuid,
      'dead_letter', 5, statement_timestamp() - interval '2 hours', null::timestamptz,
      null::uuid, null::timestamptz, 'delivery failed after bounded retries'
    )
)
INSERT INTO notification_outbox (
  id, claim_id, organization_id, channel, notification_type,
  evidence_version, deduplication_key, payload, status, attempts,
  available_at, sent_at, last_error, lease_token, lease_expires_at,
  created_at, updated_at
)
SELECT
  fixture.id,
  '7f000000-0000-4000-8000-000000000021',
  '20000000-0000-4000-8000-000000000001',
  'webhook', 'new_claim', 1,
  'synthetic-operational-dashboard-' || fixture.id::text,
  jsonb_build_object(
    'contract_version', 'notification-v1',
    'alert_id', fixture.id::text,
    'notification_type', 'new_claim',
    'created_at', statement_timestamp()::text,
    'organization', jsonb_build_object(
      'id', '20000000-0000-4000-8000-000000000001',
      'name', 'Synthetic Dashboard Organization'
    ),
    'claim', jsonb_build_object(
      'id', '7f000000-0000-4000-8000-000000000021',
      'evidence_version', 1,
      'victim_name', 'Synthetic Dashboard Victim',
      'threat_actor', null,
      'claimed_at', null,
      'first_seen_at', statement_timestamp()::text,
      'last_seen_at', statement_timestamp()::text,
      'verification_status', 'claimed'
    ),
    'match', jsonb_build_object(
      'method', 'name_exact',
      'confidence_score', 95,
      'review_status', 'auto_accepted'
    ),
    'analysis', jsonb_build_object(
      'id', '7f000000-0000-4000-8000-000000000051',
      'provider', 'ollama',
      'deployment_name', 'synthetic-model',
      'model_name', 'synthetic-model',
      'validation_status', 'fallback',
      'summary_fr', 'Donnee synthetique de validation operationnelle.',
      'observed_facts', jsonb_build_array(),
      'uncertainties', jsonb_build_array('Donnee exclusivement synthetique.')
    ),
    'sources', jsonb_build_array(jsonb_build_object(
      'name', 'synthetic-source',
      'discovered_at', statement_timestamp()::text,
      'published_at', null
    )),
    'disclaimer', U&'D\00E9claration criminelle non v\00E9rifi\00E9e ; aucune compromission n\2019est confirm\00E9e.'
  ),
  fixture.status, fixture.attempts, fixture.available_at, fixture.sent_at,
  fixture.last_error, fixture.lease_token, fixture.lease_expires_at,
  statement_timestamp() - interval '2 hours', statement_timestamp()
FROM fixtures AS fixture;

DO $$
DECLARE
  source_row record;
  channel_row record;
  baseline_row record;
  summary_row record;
BEGIN
  SELECT * INTO STRICT source_row
  FROM operational_source_dashboard
  WHERE slug = 'synthetic-dashboard-source';

  IF source_row.health_status <> 'degraded'
    OR source_row.attention_level <> 'critical'
    OR source_row.attention_reason <> 'latest_collection_failed'
    OR source_row.consecutive_failure_count <> 3
    OR source_row.latest_failure_code <> 'upstream_unavailable'
  THEN
    RAISE EXCEPTION 'source operational dashboard classification is invalid';
  END IF;

  SELECT * INTO STRICT channel_row
  FROM operational_notification_dashboard
  WHERE channel = 'webhook';
  SELECT * INTO STRICT baseline_row FROM dashboard_notification_baseline;

  IF channel_row.health_status <> 'critical'
    OR channel_row.total_job_count <> baseline_row.total_job_count + 4
    OR channel_row.ready_count <> baseline_row.ready_count + 1
    OR channel_row.processing_count <> baseline_row.processing_count + 1
    OR channel_row.expired_lease_count <> baseline_row.expired_lease_count + 1
    OR channel_row.sent_last_24h_count <> baseline_row.sent_last_24h_count + 1
    OR channel_row.dead_letter_count <> baseline_row.dead_letter_count + 1
  THEN
    RAISE EXCEPTION 'notification operational dashboard aggregation is invalid';
  END IF;

  IF (SELECT health_status FROM operational_notification_dashboard WHERE channel = 'email') <> 'disabled'
    OR (SELECT health_status FROM operational_notification_dashboard WHERE channel = 'teams') NOT IN ('healthy', 'backlog', 'degraded', 'critical')
  THEN
    RAISE EXCEPTION 'notification channel configuration is not represented safely';
  END IF;

  SELECT * INTO STRICT summary_row FROM operational_dashboard_summary;
  IF summary_row.source_attention_count < 1
    OR summary_row.critical_source_count < 1
    OR summary_row.channel_attention_count < 1
    OR summary_row.dead_letter_notification_count < 1
    OR summary_row.expired_notification_lease_count < 1
  THEN
    RAISE EXCEPTION 'operational dashboard summary is incomplete';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name IN (
        'operational_source_dashboard',
        'operational_notification_dashboard',
        'operational_dashboard_summary'
      )
      AND column_name IN (
        'payload', 'last_error', 'error_message', 'response_excerpt',
        'lease_token', 'deduplication_key', 'victim_name'
      )
  ) THEN
    RAISE EXCEPTION 'operational dashboards expose unsafe detail';
  END IF;
END;
$$;

ROLLBACK;

\echo 'Operational dashboards runtime validation passed.'
