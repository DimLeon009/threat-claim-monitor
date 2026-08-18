BEGIN;

CREATE OR REPLACE FUNCTION find_exact_organization_matches(
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
PARALLEL SAFE
AS $$
  WITH raw_candidates AS (
    SELECT
      organization.id AS organization_id,
      'domain_exact'::text AS matching_method,
      100::smallint AS confidence_score,
      1 AS method_rank,
      jsonb_build_object(
        'rule_version', 'exact-v1',
        'candidate_domain', normalize_domain(candidate_victim_domain),
        'approved_domain', normalize_domain(approved_domain)
      ) AS evidence
    FROM organizations AS organization
    CROSS JOIN LATERAL unnest(organization.domains) AS approved_domain
    WHERE organization.enabled = true
      AND domain_matches_registered(candidate_victim_domain, approved_domain)

    UNION ALL

    SELECT
      organization.id,
      'name_exact'::text,
      95::smallint,
      2,
      jsonb_build_object(
        'rule_version', 'exact-v1',
        'normalized_candidate', normalize_match_text(candidate_victim_name),
        'normalized_official_name', normalize_match_text(organization.name)
      )
    FROM organizations AS organization
    WHERE organization.enabled = true
      AND normalize_match_text(candidate_victim_name) = normalize_match_text(organization.name)

    UNION ALL

    SELECT
      organization.id,
      'alias_exact'::text,
      alias.confidence_score,
      3,
      jsonb_build_object(
        'rule_version', 'exact-v1',
        'normalized_candidate', normalize_match_text(candidate_victim_name),
        'approved_alias', alias.alias,
        'normalized_alias', normalize_match_text(alias.alias)
      )
    FROM organizations AS organization
    JOIN organization_aliases AS alias
      ON alias.organization_id = organization.id
    WHERE organization.enabled = true
      AND alias.matching_mode = 'exact'
      AND normalize_match_text(candidate_victim_name) = normalize_match_text(alias.alias)
  ), ranked AS (
    SELECT
      raw_candidates.*,
      row_number() OVER (
        PARTITION BY raw_candidates.organization_id
        ORDER BY raw_candidates.confidence_score DESC, raw_candidates.method_rank
      ) AS organization_rank
    FROM raw_candidates
  ), best_per_organization AS (
    SELECT
      ranked.organization_id,
      ranked.matching_method,
      ranked.confidence_score,
      ranked.evidence,
      count(*) OVER () AS candidate_organization_count
    FROM ranked
    WHERE ranked.organization_rank = 1
  )
  SELECT
    best_per_organization.organization_id,
    best_per_organization.matching_method,
    best_per_organization.confidence_score,
    CASE
      WHEN best_per_organization.candidate_organization_count = 1 THEN 'auto_accepted'
      ELSE 'pending'
    END AS review_status,
    best_per_organization.evidence || jsonb_build_object(
      'candidate_organization_count', best_per_organization.candidate_organization_count,
      'collision', best_per_organization.candidate_organization_count > 1,
      'auto_alert_eligible', best_per_organization.candidate_organization_count = 1
    ) AS evidence
  FROM best_per_organization
  ORDER BY best_per_organization.confidence_score DESC, best_per_organization.organization_id;
$$;

INSERT INTO schema_migrations (version)
VALUES ('005_exact_organization_matching')
ON CONFLICT (version) DO NOTHING;

COMMIT;
