\set ON_ERROR_STOP on

BEGIN;

DO $$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM sources
    WHERE id = '7d000000-0000-4000-8000-000000000001'
       OR slug = 'tcm-synthetic-demo'
  ) THEN
    RAISE EXCEPTION 'synthetic demo already exists; verify it or run cleanup_end_to_end.sql';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM organizations
    WHERE id = '7d000000-0000-4000-8000-000000000002'
       OR normalized_name = 'tcm synthetic demo organization'
  ) THEN
    RAISE EXCEPTION 'synthetic demo organization already exists; run the scoped cleanup first';
  END IF;
END;
$$;

INSERT INTO sources (
  id, slug, name, source_kind, base_url, enabled, poll_interval_minutes, metadata
)
VALUES (
  '7d000000-0000-4000-8000-000000000001',
  'tcm-synthetic-demo',
  'TCM synthetic demo',
  'json',
  'https://tcm-synthetic-demo.invalid',
  true,
  1440,
  '{"synthetic":true,"fixture":"m6-end-to-end-v1","priority":"demo-only"}'::jsonb
);

INSERT INTO organizations (
  id, name, normalized_name, domains, enabled
)
VALUES (
  '7d000000-0000-4000-8000-000000000002',
  'TCM Synthetic Demo Organization',
  normalize_match_text('TCM Synthetic Demo Organization'),
  ARRAY['tcm-synthetic-demo.invalid'],
  true
);

INSERT INTO collection_runs (
  id, source_id, started_at, finished_at, status,
  fetched_count, inserted_count, metadata
)
VALUES (
  '7d000000-0000-4000-8000-000000000010',
  '7d000000-0000-4000-8000-000000000001',
  clock_timestamp(),
  clock_timestamp(),
  'succeeded',
  1,
  1,
  '{"synthetic":true,"fixture":"m6-end-to-end-v1","is_baseline":false,"response_validation":"accepted"}'::jsonb
);

WITH synthetic_payload AS (
  SELECT jsonb_build_object(
    'fixture', 'm6-end-to-end-v1',
    'synthetic', true,
    'title', 'TCM Synthetic Demo Organization',
    'published_at', clock_timestamp()
  ) AS payload
)
INSERT INTO observations (
  id, source_id, collection_run_id, source_event_id, source_key,
  fetched_at, discovered_at, published_at,
  victim_name, normalized_victim_name, victim_domain,
  threat_actor, normalized_threat_actor, title, description,
  payload_hash, raw_payload, is_historical
)
SELECT
  '7d000000-0000-4000-8000-000000000011',
  '7d000000-0000-4000-8000-000000000001',
  '7d000000-0000-4000-8000-000000000010',
  'm6-end-to-end-v1',
  'm6-end-to-end-v1',
  clock_timestamp(),
  clock_timestamp(),
  clock_timestamp() - interval '5 minutes',
  'TCM Synthetic Demo Organization',
  normalize_match_text('TCM Synthetic Demo Organization'),
  'tcm-synthetic-demo.invalid',
  'TCM Synthetic Actor',
  normalize_threat_actor('TCM Synthetic Actor'),
  'TCM Synthetic Demo Organization',
  'Synthetic fixture only; no real incident or organization is represented.',
  encode(digest(payload::text, 'sha256'), 'hex'),
  payload,
  false
FROM synthetic_payload;

CREATE TEMP TABLE demo_correlation_result ON COMMIT DROP AS
SELECT *
FROM correlate_collection_run_exact(
  '7d000000-0000-4000-8000-000000000010'::uuid
);

DO $$
DECLARE
  resolved_claim_id uuid;
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM demo_correlation_result
    WHERE processed_observation_count = 1
      AND created_claim_count = 1
      AND created_link_count = 1
      AND persisted_match_count = 1
      AND auto_accepted_match_count = 1
  ) THEN
    RAISE EXCEPTION 'synthetic demo did not produce the expected exact-match correlation';
  END IF;

  SELECT link.claim_id
  INTO resolved_claim_id
  FROM claim_observations AS link
  WHERE link.observation_id = '7d000000-0000-4000-8000-000000000011';

  IF resolved_claim_id IS NULL THEN
    RAISE EXCEPTION 'synthetic demo claim was not created';
  END IF;

  UPDATE collection_runs
  SET metadata = metadata || jsonb_build_object('demo_claim_id', resolved_claim_id)
  WHERE id = '7d000000-0000-4000-8000-000000000010';
END;
$$;

COMMIT;

SELECT
  run.id AS collection_run_id,
  (run.metadata->>'demo_claim_id')::uuid AS claim_id,
  match.matching_method,
  match.confidence_score,
  match.review_status
FROM collection_runs AS run
JOIN organization_matches AS match
  ON match.claim_id = (run.metadata->>'demo_claim_id')::uuid
WHERE run.id = '7d000000-0000-4000-8000-000000000010'
  AND match.organization_id = '7d000000-0000-4000-8000-000000000002';

\echo 'Synthetic M6 collection, correlation, and exact matching passed.'
