BEGIN;

CREATE TABLE IF NOT EXISTS analysis_routing_policy (
  id smallint PRIMARY KEY DEFAULT 1 CHECK (id = 1),
  selected_provider text NOT NULL DEFAULT 'ollama'
    CHECK (selected_provider IN ('ollama', 'microsoft_foundry')),
  effective_from timestamptz NOT NULL DEFAULT '2000-01-01T00:00:00Z',
  change_reason text NOT NULL DEFAULT 'initial local-only routing',
  updated_at timestamptz NOT NULL DEFAULT now()
);

INSERT INTO analysis_routing_policy (id)
VALUES (1)
ON CONFLICT (id) DO NOTHING;

CREATE OR REPLACE FUNCTION get_analysis_routing_decision()
RETURNS TABLE (
  selected_provider text,
  deployment_name text,
  effective_from timestamptz,
  route_ready boolean
)
LANGUAGE sql
STABLE
AS $$
  SELECT
    policy.selected_provider,
    CASE
      WHEN policy.selected_provider = 'ollama' THEN 'qwen3:8b-q4_K_M'
      ELSE foundry.deployment_name
    END AS deployment_name,
    policy.effective_from,
    CASE
      WHEN policy.selected_provider = 'ollama' THEN true
      ELSE coalesce(foundry.enabled, false)
        AND foundry.deployment_name IS NOT NULL
    END AS route_ready
  FROM analysis_routing_policy AS policy
  LEFT JOIN analysis_provider_configs AS foundry
    ON foundry.provider = 'microsoft_foundry'
  WHERE policy.id = 1;
$$;

CREATE OR REPLACE FUNCTION set_analysis_routing_provider(
  requested_provider text,
  requested_change_reason text
)
RETURNS TABLE (
  selected_provider text,
  effective_from timestamptz,
  changed boolean,
  updated_at timestamptz
)
LANGUAGE plpgsql
AS $$
DECLARE
  policy_record analysis_routing_policy%ROWTYPE;
  normalized_reason text := nullif(trim(requested_change_reason), '');
BEGIN
  IF requested_provider IS NULL
    OR requested_provider NOT IN ('ollama', 'microsoft_foundry')
  THEN
    RAISE EXCEPTION 'unsupported analysis routing provider';
  END IF;
  IF normalized_reason IS NULL OR length(normalized_reason) > 200 THEN
    RAISE EXCEPTION 'analysis routing reason must contain between 1 and 200 characters';
  END IF;
  IF normalized_reason ~* 'https?://|api[_-]?key|authorization|bearer[[:space:]]|secret|token|password|credential' THEN
    RAISE EXCEPTION 'analysis routing reason contains prohibited secret-like material';
  END IF;

  SELECT *
  INTO STRICT policy_record
  FROM analysis_routing_policy
  WHERE id = 1
  FOR UPDATE;

  IF requested_provider = 'microsoft_foundry'
    AND NOT EXISTS (
      SELECT 1
      FROM analysis_provider_configs AS config
      WHERE config.provider = 'microsoft_foundry'
        AND config.enabled = true
        AND config.deployment_name IS NOT NULL
    )
  THEN
    RAISE EXCEPTION 'Microsoft Foundry routing requires an enabled reviewed provider configuration';
  END IF;

  IF policy_record.selected_provider = requested_provider THEN
    selected_provider := policy_record.selected_provider;
    effective_from := policy_record.effective_from;
    changed := false;
    updated_at := policy_record.updated_at;
    RETURN NEXT;
    RETURN;
  END IF;

  RETURN QUERY
  UPDATE analysis_routing_policy AS policy
  SET selected_provider = requested_provider,
      effective_from = clock_timestamp(),
      change_reason = normalized_reason,
      updated_at = clock_timestamp()
  WHERE policy.id = 1
  RETURNING
    policy.selected_provider,
    policy.effective_from,
    true,
    policy.updated_at;
END;
$$;

CREATE OR REPLACE FUNCTION get_routed_pending_claim_analysis_jobs(
  requested_prompt_version text,
  requested_provider text,
  requested_deployment_name text,
  requested_limit integer DEFAULT 10
)
RETURNS TABLE (
  claim_id uuid,
  evidence_version integer,
  input_payload jsonb,
  input_hash text
)
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
  IF requested_prompt_version IS NULL
    OR requested_prompt_version <> 'claim-analysis-v1'
  THEN
    RAISE EXCEPTION 'unsupported analysis prompt version';
  END IF;
  IF requested_provider IS NULL
    OR requested_provider NOT IN ('ollama', 'microsoft_foundry')
  THEN
    RAISE EXCEPTION 'unsupported analysis provider';
  END IF;
  IF requested_deployment_name IS NULL
    OR length(requested_deployment_name) NOT BETWEEN 1 AND 200
  THEN
    RAISE EXCEPTION 'invalid analysis deployment name';
  END IF;
  IF requested_limit NOT BETWEEN 1 AND 50 THEN
    RAISE EXCEPTION 'analysis job limit must be between 1 and 50';
  END IF;

  RETURN QUERY
  WITH route AS (
    SELECT decision.*
    FROM get_analysis_routing_decision() AS decision
    WHERE decision.route_ready = true
      AND decision.selected_provider = requested_provider
      AND decision.deployment_name = requested_deployment_name
  ), eligible AS (
    SELECT DISTINCT claim.id, claim.evidence_version, claim.updated_at
    FROM claims AS claim
    CROSS JOIN route
    JOIN organization_matches AS match ON match.claim_id = claim.id
    WHERE claim.updated_at >= route.effective_from
      AND match.review_status IN ('auto_accepted', 'accepted')
      AND EXISTS (
        SELECT 1
        FROM claim_observations AS link
        JOIN observations AS observation ON observation.id = link.observation_id
        WHERE link.claim_id = claim.id
          AND observation.is_historical = false
      )
  ), prepared AS (
    SELECT
      eligible.id,
      eligible.evidence_version,
      eligible.updated_at,
      build_claim_analysis_input(eligible.id) AS payload
    FROM eligible
  ), hashed AS (
    SELECT
      prepared.*,
      encode(digest(prepared.payload::text, 'sha256'), 'hex') AS payload_hash
    FROM prepared
  )
  SELECT hashed.id, hashed.evidence_version, hashed.payload, hashed.payload_hash
  FROM hashed
  WHERE length(hashed.payload::text) <= 12000
    AND NOT EXISTS (
      SELECT 1
      FROM analyses AS analysis
      WHERE analysis.claim_id = hashed.id
        AND analysis.prompt_version = requested_prompt_version
        AND analysis.input_hash = hashed.payload_hash
        AND analysis.provider = requested_provider
        AND analysis.deployment_name = requested_deployment_name
    )
  ORDER BY hashed.updated_at, hashed.id
  LIMIT requested_limit;
END;
$$;

INSERT INTO schema_migrations (version)
VALUES ('026_analysis_provider_routing')
ON CONFLICT (version) DO NOTHING;

COMMIT;
