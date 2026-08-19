\set ON_ERROR_STOP on

BEGIN;

INSERT INTO collection_runs (
  id, source_id, finished_at, status, fetched_count, inserted_count, metadata
)
VALUES
  (
    '79000000-0000-4000-8000-000000000001',
    '10000000-0000-4000-8000-000000000001',
    now(), 'succeeded', 1, 1, '{"fixture":"cross-source-primary"}'::jsonb
  ),
  (
    '79000000-0000-4000-8000-000000000002',
    '10000000-0000-4000-8000-000000000002',
    now(), 'succeeded', 1, 1, '{"fixture":"cross-source-secondary"}'::jsonb
  );

INSERT INTO observations (
  id, source_id, collection_run_id, source_key, discovered_at,
  victim_name, normalized_victim_name, victim_domain, threat_actor,
  normalized_threat_actor, payload_hash, raw_payload, is_historical
)
VALUES
  (
    '79000000-0000-4000-8000-000000000011',
    '10000000-0000-4000-8000-000000000001',
    '79000000-0000-4000-8000-000000000001',
    'synthetic-cross-source-primary', '2026-08-18T10:00:00Z',
    'Cross Source Example', 'cross source example', 'cross-source.invalid',
    'Synthetic Cross Actor', 'synthetic cross actor', repeat('1', 64),
    '{"fixture":"primary"}'::jsonb, false
  ),
  (
    '79000000-0000-4000-8000-000000000012',
    '10000000-0000-4000-8000-000000000002',
    '79000000-0000-4000-8000-000000000002',
    'synthetic-cross-source-secondary', '2026-08-18T11:00:00Z',
    'Cross Source Example', 'cross source example', 'cross-source.invalid',
    'Synthetic Cross Actor', 'synthetic cross actor', repeat('2', 64),
    '{"fixture":"secondary"}'::jsonb, false
  );

SELECT * FROM correlate_collection_run_exact('79000000-0000-4000-8000-000000000001');
SELECT * FROM correlate_collection_run_exact('79000000-0000-4000-8000-000000000002');

DO $$
DECLARE
  resolved_claim_id uuid;
  resolved_status text;
  resolved_version integer;
  resolved_source_count integer;
BEGIN
  SELECT primary_link.claim_id
  INTO resolved_claim_id
  FROM claim_observations AS primary_link
  JOIN claim_observations AS secondary_link
    ON secondary_link.claim_id = primary_link.claim_id
  WHERE primary_link.observation_id = '79000000-0000-4000-8000-000000000011'
    AND secondary_link.observation_id = '79000000-0000-4000-8000-000000000012';

  IF resolved_claim_id IS NULL THEN
    RAISE EXCEPTION 'cross-source observations did not correlate to one claim';
  END IF;

  SELECT claim.verification_status, claim.evidence_version,
         count(DISTINCT observation.source_id)::integer
  INTO resolved_status, resolved_version, resolved_source_count
  FROM claims AS claim
  JOIN claim_observations AS link ON link.claim_id = claim.id
  JOIN observations AS observation ON observation.id = link.observation_id
  WHERE claim.id = resolved_claim_id
  GROUP BY claim.verification_status, claim.evidence_version;

  IF resolved_status <> 'multi_source_observed'
    OR resolved_version <> 2
    OR resolved_source_count <> 2
  THEN
    RAISE EXCEPTION 'multi-source claim state is invalid';
  END IF;
END;
$$;

SELECT * FROM correlate_collection_run_exact('79000000-0000-4000-8000-000000000002');

DO $$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM claims AS claim
    JOIN claim_observations AS link ON link.claim_id = claim.id
    WHERE link.observation_id = '79000000-0000-4000-8000-000000000012'
      AND (
        claim.verification_status <> 'multi_source_observed'
        OR claim.evidence_version <> 2
      )
  ) THEN
    RAISE EXCEPTION 'cross-source correlation replay changed claim state';
  END IF;
END;
$$;

ROLLBACK;

\echo 'Cross-source correlation validation passed.'
