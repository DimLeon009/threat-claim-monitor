BEGIN;

CREATE TABLE IF NOT EXISTS threat_actors (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  canonical_name text NOT NULL,
  normalized_name text NOT NULL UNIQUE,
  enabled boolean NOT NULL DEFAULT true,
  metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CHECK (normalized_name = normalize_match_text(canonical_name))
);

CREATE TABLE IF NOT EXISTS threat_actor_aliases (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  threat_actor_id uuid NOT NULL REFERENCES threat_actors(id) ON DELETE CASCADE,
  alias text NOT NULL,
  normalized_alias text NOT NULL UNIQUE,
  enabled boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  CHECK (normalized_alias = normalize_match_text(alias))
);

CREATE OR REPLACE FUNCTION resolve_threat_actor(input_value text)
RETURNS TABLE (
  threat_actor_id uuid,
  canonical_name text,
  canonical_normalized_name text,
  resolution_method text
)
LANGUAGE plpgsql
STABLE
STRICT
AS $$
DECLARE
  normalized_input text := normalize_match_text(input_value);
  candidate_actor_count integer;
BEGIN
  IF normalized_input IS NULL THEN
    RETURN;
  END IF;

  WITH candidates AS (
    SELECT actor.id AS actor_id
    FROM threat_actors AS actor
    WHERE actor.enabled = true
      AND actor.normalized_name = normalized_input

    UNION ALL

    SELECT actor.id AS actor_id
    FROM threat_actor_aliases AS alias
    JOIN threat_actors AS actor ON actor.id = alias.threat_actor_id
    WHERE actor.enabled = true
      AND alias.enabled = true
      AND alias.normalized_alias = normalized_input
  )
  SELECT count(DISTINCT candidates.actor_id)::integer
  INTO candidate_actor_count
  FROM candidates;

  IF candidate_actor_count > 1 THEN
    RAISE EXCEPTION 'ambiguous threat actor alias configuration';
  END IF;

  IF candidate_actor_count = 1 THEN
    RETURN QUERY
    WITH candidates AS (
      SELECT actor.id AS actor_id,
             actor.canonical_name AS actor_name,
             actor.normalized_name AS actor_normalized_name,
             'canonical_exact'::text AS method,
             1 AS priority
      FROM threat_actors AS actor
      WHERE actor.enabled = true
        AND actor.normalized_name = normalized_input

      UNION ALL

      SELECT actor.id AS actor_id,
             actor.canonical_name AS actor_name,
             actor.normalized_name AS actor_normalized_name,
             'alias_exact'::text AS method,
             2 AS priority
      FROM threat_actor_aliases AS alias
      JOIN threat_actors AS actor ON actor.id = alias.threat_actor_id
      WHERE actor.enabled = true
        AND alias.enabled = true
        AND alias.normalized_alias = normalized_input
    )
    SELECT candidates.actor_id,
           candidates.actor_name,
           candidates.actor_normalized_name,
           candidates.method
    FROM candidates
    ORDER BY candidates.priority
    LIMIT 1;
    RETURN;
  END IF;

  RETURN QUERY
  SELECT NULL::uuid, trim(input_value), normalized_input, 'unmapped'::text;
END;
$$;

CREATE OR REPLACE FUNCTION normalize_threat_actor(input_value text)
RETURNS text
LANGUAGE sql
STABLE
STRICT
AS $$
  SELECT resolved.canonical_normalized_name
  FROM resolve_threat_actor(input_value) AS resolved;
$$;

INSERT INTO schema_migrations (version)
VALUES ('008_threat_actor_aliases')
ON CONFLICT (version) DO NOTHING;

COMMIT;
