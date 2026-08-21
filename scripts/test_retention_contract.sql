\set ON_ERROR_STOP on

BEGIN;

INSERT INTO sources (
  id, slug, name, source_kind, base_url, enabled, poll_interval_minutes, metadata
)
VALUES (
  '7e000000-0000-4000-8000-000000000001',
  'synthetic-retention-source',
  'Synthetic Retention Source',
  'api',
  'https://retention.invalid',
  true,
  60,
  '{"fixture":"retention-contract"}'::jsonb
);

INSERT INTO collection_runs (
  id, source_id, started_at, finished_at, status, fetched_count, inserted_count, metadata
)
VALUES
  (
    '7e000000-0000-4000-8000-000000000011',
    '7e000000-0000-4000-8000-000000000001',
    clock_timestamp() - interval '130 days', clock_timestamp() - interval '130 days',
    'succeeded', 0, 0, '{"fixture":"old-redundant-success"}'::jsonb
  ),
  (
    '7e000000-0000-4000-8000-000000000012',
    '7e000000-0000-4000-8000-000000000001',
    clock_timestamp() - interval '120 days', clock_timestamp() - interval '120 days',
    'failed', 0, 0, '{"fixture":"old-redundant-failure"}'::jsonb
  ),
  (
    '7e000000-0000-4000-8000-000000000013',
    '7e000000-0000-4000-8000-000000000001',
    clock_timestamp() - interval '110 days', clock_timestamp() - interval '110 days',
    'succeeded', 1, 1, '{"fixture":"old-evidence-run"}'::jsonb
  ),
  (
    '7e000000-0000-4000-8000-000000000014',
    '7e000000-0000-4000-8000-000000000001',
    clock_timestamp() - interval '2 days', clock_timestamp() - interval '2 days',
    'succeeded', 0, 0, '{"fixture":"latest-success"}'::jsonb
  ),
  (
    '7e000000-0000-4000-8000-000000000015',
    '7e000000-0000-4000-8000-000000000001',
    clock_timestamp() - interval '100 days', clock_timestamp() - interval '100 days',
    'partial', 0, 0, '{"fixture":"latest-failure"}'::jsonb
  ),
  (
    '7e000000-0000-4000-8000-000000000016',
    '7e000000-0000-4000-8000-000000000001',
    clock_timestamp() - interval '140 days', null,
    'running', 0, 0, '{"fixture":"running"}'::jsonb
  );

INSERT INTO observations (
  id, source_id, collection_run_id, source_key, fetched_at,
  victim_name, normalized_victim_name, payload_hash, raw_payload, is_historical
)
VALUES (
  '7e000000-0000-4000-8000-000000000021',
  '7e000000-0000-4000-8000-000000000001',
  '7e000000-0000-4000-8000-000000000013',
  'synthetic-retention-evidence',
  clock_timestamp() - interval '110 days',
  'Synthetic Retention Victim',
  'synthetic retention victim',
  repeat('e', 64),
  '{"fixture":"retention-evidence"}'::jsonb,
  false
);

SELECT * FROM set_retention_policy(true, 30, 1);

DO $$
DECLARE
  preview record;
BEGIN
  SELECT * INTO preview FROM preview_retention_job();
  IF preview.enabled IS DISTINCT FROM true
    OR preview.eligible_collection_run_count <> 2
    OR preview.max_collection_runs_per_job <> 1
  THEN
    RAISE EXCEPTION 'retention preview did not identify the bounded safe candidates';
  END IF;
END;
$$;

CREATE TEMP TABLE first_retention_run AS
SELECT * FROM run_retention_job();

CREATE TEMP TABLE second_retention_run AS
SELECT * FROM run_retention_job();

DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM first_retention_run
    WHERE result_status <> 'succeeded' OR deleted_collection_run_count <> 1
  ) OR EXISTS (
    SELECT 1 FROM second_retention_run
    WHERE result_status <> 'succeeded' OR deleted_collection_run_count <> 1
  ) THEN
    RAISE EXCEPTION 'retention row limit or deletion count is invalid';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM collection_runs
    WHERE id IN (
      '7e000000-0000-4000-8000-000000000011',
      '7e000000-0000-4000-8000-000000000012'
    )
  ) THEN
    RAISE EXCEPTION 'eligible empty collection runs were not removed';
  END IF;

  IF (
    SELECT count(*)
    FROM collection_runs
    WHERE id IN (
      '7e000000-0000-4000-8000-000000000013',
      '7e000000-0000-4000-8000-000000000014',
      '7e000000-0000-4000-8000-000000000015',
      '7e000000-0000-4000-8000-000000000016'
    )
  ) <> 4 THEN
    RAISE EXCEPTION 'retention removed evidence, current health state, or a running collection';
  END IF;

  IF (SELECT count(*) FROM retention_runs WHERE policy_snapshot->>'max_collection_runs_per_job' = '1') <> 2
    OR EXISTS (
      SELECT 1
      FROM retention_runs
      WHERE policy_snapshot::text ~* 'secret|token|password|credential|authorization'
    )
  THEN
    RAISE EXCEPTION 'retention audit history is missing or unsafe';
  END IF;

  IF (SELECT eligible_collection_run_count FROM preview_retention_job()) <> 0 THEN
    RAISE EXCEPTION 'retention replay is not idempotent';
  END IF;
END;
$$;

SELECT * FROM set_retention_policy(false, 30, 1);

DO $$
DECLARE
  disabled_result record;
  audit_count bigint;
BEGIN
  SELECT count(*) INTO audit_count FROM retention_runs;
  SELECT * INTO disabled_result FROM run_retention_job();
  IF disabled_result.result_status <> 'disabled'
    OR disabled_result.deleted_collection_run_count <> 0
    OR (SELECT count(*) FROM retention_runs) <> audit_count
  THEN
    RAISE EXCEPTION 'disabled retention job changed data or audit history';
  END IF;

  BEGIN
    PERFORM * FROM set_retention_policy(true, 6, 100);
    RAISE EXCEPTION 'unsafe retention window was accepted';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'collection-run retention days must be between 7 and 3650' THEN
      RAISE;
    END IF;
  END;
END;
$$;

ROLLBACK;

\echo 'Configurable retention runtime validation passed.'
