\set ON_ERROR_STOP on

BEGIN;

INSERT INTO sources (
  id, slug, name, source_kind, base_url, enabled, poll_interval_minutes, metadata
)
VALUES (
  '79500000-0000-4000-8000-000000000001',
  'synthetic-health-source',
  'Synthetic Health Source',
  'api',
  'https://source-health.invalid',
  true,
  15,
  '{"fixture":"source-health"}'::jsonb
);

INSERT INTO collection_runs (
  id, source_id, started_at, finished_at, status,
  fetched_count, inserted_count, error_message, metadata
)
VALUES
  (
    '79500000-0000-4000-8000-000000000011',
    '79500000-0000-4000-8000-000000000001',
    clock_timestamp() - interval '30 minutes',
    clock_timestamp() - interval '29 minutes',
    'succeeded', 10, 8, NULL,
    '{"contract_version":"synthetic-health-v1"}'::jsonb
  ),
  (
    '79500000-0000-4000-8000-000000000012',
    '79500000-0000-4000-8000-000000000001',
    clock_timestamp() - interval '20 minutes',
    clock_timestamp() - interval '19 minutes',
    'failed', 0, 0, 'sanitized synthetic failure',
    '{"contract_version":"synthetic-health-v1","failure_code":"fetch_failed"}'::jsonb
  ),
  (
    '79500000-0000-4000-8000-000000000013',
    '79500000-0000-4000-8000-000000000001',
    clock_timestamp() - interval '10 minutes',
    clock_timestamp() - interval '9 minutes',
    'failed', 0, 0, 'sanitized synthetic validation failure',
    '{"contract_version":"synthetic-health-v2","failure_code":"response_validation_failed"}'::jsonb
  );

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM source_health
    WHERE slug = 'synthetic-health-source'
      AND health_status = 'degraded'
      AND consecutive_failure_count = 2
      AND latest_response_validation = 'rejected'
      AND latest_contract_version = 'synthetic-health-v2'
      AND latest_fetched_count = 0
      AND latest_inserted_count = 0
      AND last_success_at IS NOT NULL
      AND last_failure_at IS NOT NULL
  ) THEN
    RAISE EXCEPTION 'degraded source health summary is invalid';
  END IF;
END;
$$;

SELECT * FROM set_source_enabled(
  'synthetic-health-source', false, 'synthetic maintenance window'
);

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM source_health
    WHERE slug = 'synthetic-health-source'
      AND enabled = false
      AND health_status = 'disabled'
  ) THEN
    RAISE EXCEPTION 'disabled source health state is invalid';
  END IF;

  BEGIN
    PERFORM * FROM set_source_enabled(
      'synthetic-health-source', true, 'password=unsafe'
    );
    RAISE EXCEPTION 'unsafe source state reason was accepted';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'source state change reason contains prohibited secret-like material' THEN
      RAISE;
    END IF;
  END;
END;
$$;

SELECT * FROM set_source_enabled(
  'synthetic-health-source', true, 'synthetic maintenance complete'
);

INSERT INTO collection_runs (
  id, source_id, started_at, finished_at, status,
  fetched_count, inserted_count, metadata
)
VALUES (
  '79500000-0000-4000-8000-000000000014',
  '79500000-0000-4000-8000-000000000001',
  clock_timestamp() - interval '2 minutes',
  clock_timestamp() - interval '1 minute',
  'succeeded', 12, 2,
  '{"contract_version":"synthetic-health-v2"}'::jsonb
);

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM source_health
    WHERE slug = 'synthetic-health-source'
      AND enabled = true
      AND health_status = 'healthy'
      AND consecutive_failure_count = 0
      AND latest_response_validation = 'accepted'
      AND latest_fetched_count = 12
      AND latest_inserted_count = 2
  ) THEN
    RAISE EXCEPTION 'recovered source health summary is invalid';
  END IF;
END;
$$;

ROLLBACK;

\echo 'Source health and switches validation passed.'
