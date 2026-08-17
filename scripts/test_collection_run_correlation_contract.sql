\set ON_ERROR_STOP on

BEGIN;

INSERT INTO collection_runs (
  id, source_id, finished_at, status, fetched_count, inserted_count, metadata
)
VALUES (
  '40000000-0000-4000-8000-000000000001',
  '10000000-0000-4000-8000-000000000001',
  now(),
  'succeeded',
  2,
  2,
  '{"contract_version":"synthetic-correlation-test"}'::jsonb
);

INSERT INTO observations (
  id, source_id, collection_run_id, source_key, discovered_at, published_at,
  victim_name, normalized_victim_name, victim_domain, threat_actor,
  normalized_threat_actor, payload_hash, raw_payload, is_historical
)
VALUES
  (
    '40000000-0000-4000-8000-000000000011',
    '10000000-0000-4000-8000-000000000001',
    '40000000-0000-4000-8000-000000000001',
    'synthetic-run-correlation-001', '2026-05-01T10:00:00Z', '2026-05-01T10:00:00Z',
    'CAPIFRANCE', 'capifrance', 'portal.capifrance.fr', 'Run Test Actor',
    'run test actor', repeat('7', 64), '{}', false
  ),
  (
    '40000000-0000-4000-8000-000000000012',
    '10000000-0000-4000-8000-000000000001',
    '40000000-0000-4000-8000-000000000001',
    'synthetic-run-correlation-002', '2026-05-02T10:00:00Z', '2026-05-02T10:00:00Z',
    'Capifrance', 'capifrance', 'capifrance.fr', 'Run Test Actor',
    'run test actor', repeat('8', 64), '{}', false
  );

SELECT * FROM correlate_collection_run_exact('40000000-0000-4000-8000-000000000001');

DO $$
DECLARE
  run_status text;
  run_metadata jsonb;
BEGIN
  SELECT status, metadata
  INTO run_status, run_metadata
  FROM collection_runs
  WHERE id = '40000000-0000-4000-8000-000000000001';

  IF run_status <> 'succeeded'
    OR run_metadata->>'correlation_status' <> 'succeeded'
    OR run_metadata->>'correlation_processed_count' <> '2'
    OR run_metadata->>'correlation_created_claim_count' <> '1'
    OR run_metadata->>'correlation_created_link_count' <> '2'
    OR run_metadata->>'correlation_auto_accepted_match_count' <> '2'
  THEN
    RAISE EXCEPTION 'collection run correlation summary is invalid';
  END IF;

  IF (SELECT count(*) FROM claim_observations WHERE observation_id IN (
    '40000000-0000-4000-8000-000000000011',
    '40000000-0000-4000-8000-000000000012'
  )) <> 2 THEN
    RAISE EXCEPTION 'collection run must link every inserted observation once';
  END IF;
END;
$$;

SELECT * FROM correlate_collection_run_exact('40000000-0000-4000-8000-000000000001');

DO $$
BEGIN
  IF (
    SELECT evidence_version
    FROM claims AS claim
    JOIN claim_observations AS link ON link.claim_id = claim.id
    WHERE link.observation_id = '40000000-0000-4000-8000-000000000011'
  ) <> 2 THEN
    RAISE EXCEPTION 'collection run replay must not increment evidence_version';
  END IF;
END;
$$;

SELECT * FROM record_claim_correlation_failure('40000000-0000-4000-8000-000000000001');

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM collection_runs
    WHERE id = '40000000-0000-4000-8000-000000000001'
      AND status = 'partial'
      AND error_message = 'claim correlation failed; retry the collection run correlation'
      AND metadata->>'correlation_failure_code' = 'correlation_failed'
  ) THEN
    RAISE EXCEPTION 'correlation failure must be persisted with sanitized metadata';
  END IF;
END;
$$;

SELECT * FROM correlate_collection_run_exact('40000000-0000-4000-8000-000000000001');

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM collection_runs
    WHERE id = '40000000-0000-4000-8000-000000000001'
      AND status = 'succeeded'
      AND error_message IS NULL
      AND metadata->>'correlation_status' = 'succeeded'
      AND NOT (metadata ? 'correlation_failure_code')
  ) THEN
    RAISE EXCEPTION 'successful retry must recover the collection run state';
  END IF;
END;
$$;

ROLLBACK;

\echo 'Collection-run correlation validation passed.'
