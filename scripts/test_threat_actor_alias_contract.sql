\set ON_ERROR_STOP on

BEGIN;

INSERT INTO threat_actors (id, canonical_name, normalized_name, enabled)
VALUES
  ('50000000-0000-4000-8000-000000000001', 'Example Syndicate', 'example syndicate', true),
  ('50000000-0000-4000-8000-000000000002', 'Disabled Group', 'disabled group', false),
  ('50000000-0000-4000-8000-000000000003', 'Collision Name', 'collision name', true);

INSERT INTO threat_actor_aliases (threat_actor_id, alias, normalized_alias, enabled)
VALUES
  ('50000000-0000-4000-8000-000000000001', 'Example-Syn', 'example syn', true),
  ('50000000-0000-4000-8000-000000000002', 'Disabled Alias', 'disabled alias', true),
  ('50000000-0000-4000-8000-000000000001', 'Collision-Name', 'collision name', true);

DO $$
DECLARE
  resolved record;
  collision_failed_closed boolean := false;
BEGIN
  SELECT * INTO resolved FROM resolve_threat_actor('Example-Syn');
  IF resolved.canonical_normalized_name <> 'example syndicate'
    OR resolved.resolution_method <> 'alias_exact'
  THEN
    RAISE EXCEPTION 'approved actor alias did not resolve to its canonical actor';
  END IF;

  SELECT * INTO resolved FROM resolve_threat_actor('Example Syndicate');
  IF resolved.canonical_normalized_name <> 'example syndicate'
    OR resolved.resolution_method <> 'canonical_exact'
  THEN
    RAISE EXCEPTION 'canonical actor name did not resolve exactly';
  END IF;

  SELECT * INTO resolved FROM resolve_threat_actor('Unknown_Group');
  IF resolved.canonical_normalized_name <> 'unknown group'
    OR resolved.resolution_method <> 'unmapped'
  THEN
    RAISE EXCEPTION 'unknown actor must retain deterministic text normalization';
  END IF;

  SELECT * INTO resolved FROM resolve_threat_actor('Disabled Alias');
  IF resolved.canonical_normalized_name <> 'disabled alias'
    OR resolved.resolution_method <> 'unmapped'
  THEN
    RAISE EXCEPTION 'disabled actor aliases must not resolve';
  END IF;

  BEGIN
    PERFORM normalize_threat_actor('Collision Name');
  EXCEPTION
    WHEN raise_exception THEN
      IF SQLERRM = 'ambiguous threat actor alias configuration' THEN
        collision_failed_closed := true;
      ELSE
        RAISE;
      END IF;
  END;

  IF NOT collision_failed_closed THEN
    RAISE EXCEPTION 'actor alias collision must fail closed';
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
    '50000000-0000-4000-8000-000000000011',
    '10000000-0000-4000-8000-000000000001',
    'synthetic-actor-alias-001', '2026-06-01T10:00:00Z', 'Example Victim',
    'example victim', 'Example Syndicate', 'example syndicate', repeat('9', 64), '{}', false
  ),
  (
    '50000000-0000-4000-8000-000000000012',
    '10000000-0000-4000-8000-000000000001',
    'synthetic-actor-alias-002', '2026-06-02T10:00:00Z', 'Example Victim',
    'example victim', 'Example-Syn', 'example syn', repeat('a', 64), '{}', false
  );

SELECT * FROM correlate_observation_exact('50000000-0000-4000-8000-000000000011');
SELECT * FROM correlate_observation_exact('50000000-0000-4000-8000-000000000012');

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM claim_observations AS first_link
    JOIN claim_observations AS second_link ON second_link.claim_id = first_link.claim_id
    JOIN claims AS claim ON claim.id = first_link.claim_id
    WHERE first_link.observation_id = '50000000-0000-4000-8000-000000000011'
      AND second_link.observation_id = '50000000-0000-4000-8000-000000000012'
      AND claim.normalized_threat_actor = 'example syndicate'
      AND claim.evidence_version = 2
  ) THEN
    RAISE EXCEPTION 'canonical actor and approved alias must correlate to one claim';
  END IF;
END;
$$;

ROLLBACK;

\echo 'Threat-actor alias validation passed.'
