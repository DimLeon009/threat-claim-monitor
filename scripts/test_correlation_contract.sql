\set ON_ERROR_STOP on

BEGIN;

INSERT INTO observations (
  id, source_id, source_key, discovered_at, published_at, victim_name,
  normalized_victim_name, victim_domain, threat_actor,
  normalized_threat_actor, payload_hash, raw_payload, is_historical
)
VALUES
  (
    '30000000-0000-4000-8000-000000000001',
    '10000000-0000-4000-8000-000000000001',
    'synthetic-correlation-001', '2026-01-01T10:00:00Z', '2026-01-01T10:00:00Z',
    'Example North', 'example north', 'example-north.invalid', 'Alpha Team',
    'alpha team', repeat('1', 64), '{}', false
  ),
  (
    '30000000-0000-4000-8000-000000000002',
    '10000000-0000-4000-8000-000000000001',
    'synthetic-correlation-002', '2026-02-10T10:00:00Z', '2026-02-10T10:00:00Z',
    'Example North', 'example north', 'example-north.invalid', 'Alpha Team',
    'alpha team', repeat('2', 64), '{}', false
  ),
  (
    '30000000-0000-4000-8000-000000000003',
    '10000000-0000-4000-8000-000000000001',
    'synthetic-correlation-003', '2026-04-01T10:00:00Z', '2026-04-01T10:00:00Z',
    'Example North', 'example north', 'example-north.invalid', 'Alpha Team',
    'alpha team', repeat('3', 64), '{}', false
  ),
  (
    '30000000-0000-4000-8000-000000000004',
    '10000000-0000-4000-8000-000000000001',
    'synthetic-correlation-004', '2026-02-10T10:00:00Z', '2026-02-10T10:00:00Z',
    'Example North', 'example north', 'example-north.invalid', 'Beta Team',
    'beta team', repeat('4', 64), '{}', false
  ),
  (
    '30000000-0000-4000-8000-000000000005',
    '10000000-0000-4000-8000-000000000001',
    'synthetic-correlation-005', '2026-02-11T10:00:00Z', '2026-02-11T10:00:00Z',
    'CAPIFRANCE', 'capifrance', 'portal.capifrance.fr', 'Synthetic Actor',
    'synthetic actor', repeat('5', 64), '{}', false
  );

SELECT * FROM correlate_observation_exact('30000000-0000-4000-8000-000000000001');
SELECT * FROM correlate_observation_exact('30000000-0000-4000-8000-000000000001');
SELECT * FROM correlate_observation_exact('30000000-0000-4000-8000-000000000002');
SELECT * FROM correlate_observation_exact('30000000-0000-4000-8000-000000000003');
SELECT * FROM correlate_observation_exact('30000000-0000-4000-8000-000000000004');
SELECT * FROM correlate_observation_exact('30000000-0000-4000-8000-000000000005');

DO $$
DECLARE
  first_claim_id uuid;
  second_claim_id uuid;
  replay_claim_id uuid;
  replay_version integer;
  capifrance_score integer;
  capifrance_status text;
BEGIN
  SELECT claim_id INTO first_claim_id
  FROM claim_observations
  WHERE observation_id = '30000000-0000-4000-8000-000000000001';

  SELECT claim_id INTO replay_claim_id
  FROM claim_observations
  WHERE observation_id = '30000000-0000-4000-8000-000000000002';

  IF first_claim_id IS DISTINCT FROM replay_claim_id THEN
    RAISE EXCEPTION 'observations inside the 45-day window must share one claim';
  END IF;

  SELECT evidence_version INTO replay_version
  FROM claims
  WHERE id = first_claim_id;

  IF replay_version <> 2 THEN
    RAISE EXCEPTION 'one additional linked observation must increment evidence_version to 2';
  END IF;

  SELECT claim_id INTO second_claim_id
  FROM claim_observations
  WHERE observation_id = '30000000-0000-4000-8000-000000000003';

  IF second_claim_id IS NOT DISTINCT FROM first_claim_id THEN
    RAISE EXCEPTION 'observation outside the 45-day window must create a new claim';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM claim_observations AS left_link
    JOIN claim_observations AS right_link
      ON left_link.claim_id = right_link.claim_id
    WHERE left_link.observation_id = '30000000-0000-4000-8000-000000000001'
      AND right_link.observation_id = '30000000-0000-4000-8000-000000000004'
  ) THEN
    RAISE EXCEPTION 'different threat actors must not correlate';
  END IF;

  SELECT match.confidence_score, match.review_status
  INTO capifrance_score, capifrance_status
  FROM organization_matches AS match
  JOIN claim_observations AS link ON link.claim_id = match.claim_id
  WHERE link.observation_id = '30000000-0000-4000-8000-000000000005';

  IF capifrance_score <> 100 OR capifrance_status <> 'auto_accepted' THEN
    RAISE EXCEPTION 'approved domain must persist one auto-accepted score-100 match';
  END IF;

  IF (SELECT count(*) FROM claim_observations WHERE observation_id = '30000000-0000-4000-8000-000000000001') <> 1 THEN
    RAISE EXCEPTION 'observation replay must preserve one link';
  END IF;
END;
$$;

INSERT INTO organizations (id, name, normalized_name)
VALUES (
  '20000000-0000-4000-8000-000000000099',
  'Synthetic Collision',
  'synthetic collision'
);

INSERT INTO organization_aliases (
  organization_id, alias, normalized_alias, matching_mode, confidence_score
)
VALUES (
  '20000000-0000-4000-8000-000000000099',
  'Capifrance',
  'capifrance',
  'exact',
  95
);

INSERT INTO observations (
  id, source_id, source_key, discovered_at, victim_name,
  normalized_victim_name, threat_actor, normalized_threat_actor,
  payload_hash, raw_payload, is_historical
)
VALUES (
  '30000000-0000-4000-8000-000000000006',
  '10000000-0000-4000-8000-000000000001',
  'synthetic-correlation-006', '2026-02-12T10:00:00Z', 'Capifrance',
  'capifrance', 'Collision Actor', 'collision actor', repeat('6', 64), '{}', false
);

SELECT * FROM correlate_observation_exact('30000000-0000-4000-8000-000000000006');

DO $$
BEGIN
  IF (
    SELECT count(*)
    FROM organization_matches AS match
    JOIN claim_observations AS link ON link.claim_id = match.claim_id
    WHERE link.observation_id = '30000000-0000-4000-8000-000000000006'
      AND match.review_status = 'pending'
      AND match.evidence->>'collision' = 'true'
      AND match.evidence->>'auto_alert_eligible' = 'false'
  ) <> 2 THEN
    RAISE EXCEPTION 'configuration collision must persist two pending matches';
  END IF;
END;
$$;

ROLLBACK;

\echo 'Transactional claim correlation validation passed.'
