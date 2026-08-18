\set ON_ERROR_STOP on

BEGIN;

INSERT INTO organizations (id, name, normalized_name)
VALUES
  ('60000000-0000-4000-8000-000000000001', 'Example Holdings', 'example holdings'),
  ('60000000-0000-4000-8000-000000000002', 'Northwind Property', 'northwind property');

INSERT INTO organization_aliases (
  organization_id, alias, normalized_alias, matching_mode, confidence_score
)
VALUES (
  '60000000-0000-4000-8000-000000000001',
  'Example Holdings',
  'example holdings',
  'token',
  80
);

DO $$
BEGIN
  IF approved_token_alias_matches('Example Holdings Europe', 'Example Holdings') IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'approved multi-token alias must produce a review candidate';
  END IF;

  IF approved_token_alias_matches('Example Europe', 'Example Holdings') IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'missing required token must reject the candidate';
  END IF;

  IF approved_token_alias_matches('Example Holdings', 'Holdings') IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'single-token aliases must not produce review candidates';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM find_review_organization_candidates('Example Holdings Europe', NULL)
    WHERE organization_id = '60000000-0000-4000-8000-000000000001'
      AND matching_method = 'token'
      AND confidence_score = 80
      AND review_status = 'pending'
      AND evidence->>'auto_alert_eligible' = 'false'
  ) THEN
    RAISE EXCEPTION 'token candidate must remain pending and ineligible for automatic alerting';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM find_review_organization_candidates('Northwind Proprty', NULL)
    WHERE organization_id = '60000000-0000-4000-8000-000000000002'
      AND matching_method = 'fuzzy'
      AND confidence_score <= 69
      AND review_status = 'pending'
      AND evidence->>'auto_alert_eligible' = 'false'
  ) THEN
    RAISE EXCEPTION 'fuzzy candidate must remain pending and capped below automatic scores';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM find_review_organization_candidates('Unrelated Company', NULL)
    WHERE organization_id = '60000000-0000-4000-8000-000000000002'
  ) THEN
    RAISE EXCEPTION 'unrelated organization must not produce a fuzzy candidate';
  END IF;
END;
$$;

INSERT INTO observations (
  id, source_id, source_key, discovered_at, victim_name,
  normalized_victim_name, threat_actor, normalized_threat_actor,
  payload_hash, raw_payload, is_historical
)
VALUES
  (
    '60000000-0000-4000-8000-000000000011',
    '10000000-0000-4000-8000-000000000001',
    'synthetic-review-token-001', '2026-07-01T10:00:00Z', 'Example Holdings Europe',
    'example holdings europe', 'Review Actor One', 'review actor one', repeat('b', 64), '{}', false
  ),
  (
    '60000000-0000-4000-8000-000000000012',
    '10000000-0000-4000-8000-000000000001',
    'synthetic-review-fuzzy-001', '2026-07-02T10:00:00Z', 'Northwind Proprty',
    'northwind proprty', 'Review Actor Two', 'review actor two', repeat('c', 64), '{}', false
  );

SELECT * FROM correlate_observation_exact('60000000-0000-4000-8000-000000000011');
SELECT * FROM correlate_observation_exact('60000000-0000-4000-8000-000000000012');

DO $$
BEGIN
  IF (
    SELECT count(*)
    FROM organization_matches AS match
    JOIN claim_observations AS link ON link.claim_id = match.claim_id
    WHERE link.observation_id IN (
      '60000000-0000-4000-8000-000000000011',
      '60000000-0000-4000-8000-000000000012'
    )
      AND match.review_status = 'pending'
      AND match.matching_method IN ('token', 'fuzzy')
      AND match.evidence->>'auto_alert_eligible' = 'false'
  ) <> 2 THEN
    RAISE EXCEPTION 'correlation must persist both review candidates without automatic eligibility';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM organization_matches AS match
    JOIN claim_observations AS link ON link.claim_id = match.claim_id
    WHERE link.observation_id IN (
      '60000000-0000-4000-8000-000000000011',
      '60000000-0000-4000-8000-000000000012'
    )
      AND match.review_status = 'auto_accepted'
  ) THEN
    RAISE EXCEPTION 'review candidates must never be auto accepted';
  END IF;
END;
$$;

UPDATE organization_matches AS match
SET review_status = 'accepted', reviewed_at = now()
FROM claim_observations AS link
WHERE link.claim_id = match.claim_id
  AND link.observation_id = '60000000-0000-4000-8000-000000000011';

SELECT * FROM correlate_observation_exact('60000000-0000-4000-8000-000000000011');

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM organization_matches AS match
    JOIN claim_observations AS link ON link.claim_id = match.claim_id
    WHERE link.observation_id = '60000000-0000-4000-8000-000000000011'
      AND match.review_status = 'accepted'
      AND match.reviewed_at IS NOT NULL
  ) THEN
    RAISE EXCEPTION 'candidate replay must preserve the human review decision';
  END IF;
END;
$$;

ROLLBACK;

\echo 'Review-candidate validation passed.'
