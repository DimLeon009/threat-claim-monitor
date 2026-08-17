BEGIN;

CREATE EXTENSION IF NOT EXISTS pg_trgm;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'organization_alias_token_score_check'
      AND conrelid = 'organization_aliases'::regclass
  ) THEN
    ALTER TABLE organization_aliases
      ADD CONSTRAINT organization_alias_token_score_check
      CHECK (matching_mode <> 'token' OR confidence_score BETWEEN 70 AND 84)
      NOT VALID;
  END IF;
END;
$$;

ALTER TABLE organization_aliases
  VALIDATE CONSTRAINT organization_alias_token_score_check;

CREATE OR REPLACE FUNCTION match_text_tokens(input_value text)
RETURNS text[]
LANGUAGE sql
STABLE
STRICT
AS $$
  SELECT coalesce(array_agg(DISTINCT token ORDER BY token), ARRAY[]::text[])
  FROM unnest(string_to_array(normalize_match_text(input_value), ' ')) AS token
  WHERE token <> '';
$$;

CREATE OR REPLACE FUNCTION approved_token_alias_matches(
  candidate_value text,
  approved_alias_value text
)
RETURNS boolean
LANGUAGE sql
STABLE
AS $$
  WITH candidate AS (
    SELECT match_text_tokens(candidate_value) AS tokens
  ), approved AS (
    SELECT match_text_tokens(approved_alias_value) AS tokens
  )
  SELECT CASE
    WHEN candidate.tokens IS NULL OR approved.tokens IS NULL
      OR cardinality(approved.tokens) < 2
      THEN false
    ELSE NOT EXISTS (
      SELECT 1
      FROM unnest(approved.tokens) AS required_token
      WHERE NOT (required_token = ANY(candidate.tokens))
    )
  END
  FROM candidate, approved;
$$;

CREATE OR REPLACE FUNCTION find_review_organization_candidates(
  candidate_victim_name text,
  candidate_victim_domain text
)
RETURNS TABLE (
  organization_id uuid,
  matching_method text,
  confidence_score smallint,
  review_status text,
  evidence jsonb
)
LANGUAGE sql
STABLE
AS $$
  WITH exact_organizations AS (
    SELECT exact_match.organization_id
    FROM find_exact_organization_matches(candidate_victim_name, candidate_victim_domain) AS exact_match
  ), raw_candidates AS (
    SELECT
      organization.id AS organization_id,
      'token'::text AS matching_method,
      alias.confidence_score,
      1 AS method_rank,
      jsonb_build_object(
        'rule_version', 'review-v1',
        'normalized_candidate', normalize_match_text(candidate_victim_name),
        'approved_alias', alias.alias,
        'normalized_alias', normalize_match_text(alias.alias),
        'candidate_tokens', match_text_tokens(candidate_victim_name),
        'required_tokens', match_text_tokens(alias.alias),
        'auto_alert_eligible', false
      ) AS evidence
    FROM organizations AS organization
    JOIN organization_aliases AS alias ON alias.organization_id = organization.id
    WHERE organization.enabled = true
      AND alias.matching_mode = 'token'
      AND approved_token_alias_matches(candidate_victim_name, alias.alias)

    UNION ALL

    SELECT
      organization.id,
      'fuzzy'::text,
      least(
        69,
        floor(similarity(
          normalize_match_text(candidate_victim_name),
          normalize_match_text(organization.name)
        ) * 100)::integer
      )::smallint,
      2,
      jsonb_build_object(
        'rule_version', 'review-v1',
        'normalized_candidate', normalize_match_text(candidate_victim_name),
        'normalized_official_name', normalize_match_text(organization.name),
        'similarity', round(similarity(
          normalize_match_text(candidate_victim_name),
          normalize_match_text(organization.name)
        )::numeric, 4),
        'minimum_similarity', 0.60,
        'auto_alert_eligible', false
      )
    FROM organizations AS organization
    WHERE organization.enabled = true
      AND length(normalize_match_text(candidate_victim_name)) >= 5
      AND length(normalize_match_text(organization.name)) >= 5
      AND normalize_match_text(candidate_victim_name) <> normalize_match_text(organization.name)
      AND similarity(
        normalize_match_text(candidate_victim_name),
        normalize_match_text(organization.name)
      ) >= 0.60
  ), filtered AS (
    SELECT raw_candidates.*
    FROM raw_candidates
    WHERE NOT EXISTS (
      SELECT 1
      FROM exact_organizations
      WHERE exact_organizations.organization_id = raw_candidates.organization_id
    )
  ), ranked AS (
    SELECT
      filtered.*,
      row_number() OVER (
        PARTITION BY filtered.organization_id
        ORDER BY filtered.confidence_score DESC, filtered.method_rank
      ) AS organization_rank
    FROM filtered
  )
  SELECT
    ranked.organization_id,
    ranked.matching_method,
    ranked.confidence_score,
    'pending'::text AS review_status,
    ranked.evidence || jsonb_build_object(
      'candidate_organization_count', count(*) OVER (),
      'collision', count(*) OVER () > 1,
      'auto_alert_eligible', false
    )
  FROM ranked
  WHERE ranked.organization_rank = 1
  ORDER BY ranked.confidence_score DESC, ranked.organization_id;
$$;

CREATE OR REPLACE FUNCTION persist_review_organization_candidates(
  resolved_claim_id uuid,
  observation_record_id uuid,
  candidate_victim_name text,
  candidate_victim_domain text,
  resolved_evidence_version integer
)
RETURNS integer
LANGUAGE plpgsql
AS $$
DECLARE
  affected_count integer;
BEGIN
  INSERT INTO organization_matches (
    claim_id,
    organization_id,
    matching_method,
    confidence_score,
    review_status,
    evidence
  )
  SELECT
    resolved_claim_id,
    candidate.organization_id,
    candidate.matching_method,
    candidate.confidence_score,
    'pending',
    candidate.evidence || jsonb_build_object(
      'observation_id', observation_record_id,
      'claim_evidence_version', resolved_evidence_version,
      'auto_alert_eligible', false
    )
  FROM find_review_organization_candidates(
    candidate_victim_name,
    candidate_victim_domain
  ) AS candidate
  ON CONFLICT ON CONSTRAINT organization_matches_claim_id_organization_id_key DO UPDATE
  SET matching_method = EXCLUDED.matching_method,
      confidence_score = EXCLUDED.confidence_score,
      evidence = EXCLUDED.evidence,
      review_status = 'pending'
  WHERE organization_matches.review_status = 'pending'
    AND organization_matches.matching_method IN ('token', 'fuzzy')
    AND EXCLUDED.confidence_score > organization_matches.confidence_score;

  GET DIAGNOSTICS affected_count = ROW_COUNT;
  RETURN affected_count;
END;
$$;

DO $$
BEGIN
  IF to_regprocedure('correlate_observation_exact_core(uuid)') IS NULL THEN
    ALTER FUNCTION correlate_observation_exact(uuid)
      RENAME TO correlate_observation_exact_core;
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION correlate_observation_exact(observation_record_id uuid)
RETURNS TABLE (
  claim_id uuid,
  claim_created boolean,
  observation_link_created boolean,
  evidence_version integer,
  persisted_match_count integer,
  auto_accepted_match_count integer
)
LANGUAGE plpgsql
AS $$
DECLARE
  core_result record;
  observation_record observations%ROWTYPE;
  final_match_count integer;
  final_auto_accepted_count integer;
BEGIN
  SELECT *
  INTO core_result
  FROM correlate_observation_exact_core(observation_record_id);

  SELECT *
  INTO observation_record
  FROM observations
  WHERE id = observation_record_id;

  PERFORM persist_review_organization_candidates(
    core_result.claim_id,
    observation_record.id,
    observation_record.victim_name,
    observation_record.victim_domain,
    core_result.evidence_version
  );

  SELECT
    count(*)::integer,
    count(*) FILTER (WHERE review_status = 'auto_accepted')::integer
  INTO final_match_count, final_auto_accepted_count
  FROM organization_matches AS match
  WHERE match.claim_id = core_result.claim_id;

  RETURN QUERY
  SELECT
    core_result.claim_id,
    core_result.claim_created,
    core_result.observation_link_created,
    core_result.evidence_version,
    final_match_count,
    final_auto_accepted_count;
END;
$$;

INSERT INTO schema_migrations (version)
VALUES ('009_review_match_candidates')
ON CONFLICT (version) DO NOTHING;

COMMIT;
