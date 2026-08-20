\set ON_ERROR_STOP on

BEGIN;

DO $$
DECLARE
  resolved_claim_id uuid;
BEGIN
  SELECT (metadata->>'demo_claim_id')::uuid
  INTO resolved_claim_id
  FROM collection_runs
  WHERE id = '7d000000-0000-4000-8000-000000000010'
    AND source_id = '7d000000-0000-4000-8000-000000000001'
    AND metadata @> '{"synthetic":true,"fixture":"m6-end-to-end-v1"}'::jsonb;

  IF resolved_claim_id IS NOT NULL AND EXISTS (
    SELECT 1
    FROM claim_observations AS link
    JOIN observations AS observation ON observation.id = link.observation_id
    WHERE link.claim_id = resolved_claim_id
      AND (
        observation.source_id <> '7d000000-0000-4000-8000-000000000001'
        OR observation.raw_payload->>'fixture' IS DISTINCT FROM 'm6-end-to-end-v1'
      )
  ) THEN
    RAISE EXCEPTION 'cleanup refused: synthetic claim contains non-demo evidence';
  END IF;

  IF resolved_claim_id IS NOT NULL THEN
    DELETE FROM claims WHERE id = resolved_claim_id;
  END IF;
END;
$$;

DELETE FROM observations
WHERE id = '7d000000-0000-4000-8000-000000000011'
  AND source_id = '7d000000-0000-4000-8000-000000000001'
  AND raw_payload->>'fixture' = 'm6-end-to-end-v1';

DELETE FROM collection_runs
WHERE id = '7d000000-0000-4000-8000-000000000010'
  AND source_id = '7d000000-0000-4000-8000-000000000001'
  AND metadata @> '{"synthetic":true,"fixture":"m6-end-to-end-v1"}'::jsonb;

DELETE FROM organizations
WHERE id = '7d000000-0000-4000-8000-000000000002'
  AND normalized_name = 'tcm synthetic demo organization';

DELETE FROM sources
WHERE id = '7d000000-0000-4000-8000-000000000001'
  AND slug = 'tcm-synthetic-demo'
  AND metadata @> '{"synthetic":true,"fixture":"m6-end-to-end-v1"}'::jsonb;

COMMIT;

SELECT
  NOT EXISTS (
    SELECT 1 FROM sources WHERE id = '7d000000-0000-4000-8000-000000000001'
  ) AS source_removed,
  NOT EXISTS (
    SELECT 1 FROM organizations WHERE id = '7d000000-0000-4000-8000-000000000002'
  ) AS organization_removed,
  NOT EXISTS (
    SELECT 1 FROM collection_runs WHERE id = '7d000000-0000-4000-8000-000000000010'
  ) AS run_removed;

\echo 'Synthetic M6 demonstration data removed.'
