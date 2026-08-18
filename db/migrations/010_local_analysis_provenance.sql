BEGIN;

ALTER TABLE analyses
  ADD COLUMN IF NOT EXISTS evidence_version integer CHECK (evidence_version > 0),
  ADD COLUMN IF NOT EXISTS input_payload jsonb NOT NULL DEFAULT '{}'::jsonb,
  ADD COLUMN IF NOT EXISTS inference_metadata jsonb NOT NULL DEFAULT '{}'::jsonb;

CREATE OR REPLACE FUNCTION validate_claim_analysis_output(output_payload jsonb)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
STRICT
AS $$
  SELECT jsonb_typeof(output_payload) = 'object'
    AND output_payload ?& ARRAY[
      'language', 'summary_fr', 'observed_facts', 'uncertainties', 'disclaimer'
    ]
    AND (SELECT count(*) FROM jsonb_object_keys(output_payload)) = 5
    AND output_payload->>'language' = 'fr'
    AND length(output_payload->>'summary_fr') BETWEEN 1 AND 600
    AND jsonb_typeof(output_payload->'observed_facts') = 'array'
    AND jsonb_array_length(output_payload->'observed_facts') <= 5
    AND NOT EXISTS (
      SELECT 1
      FROM jsonb_array_elements(output_payload->'observed_facts') AS fact
      WHERE jsonb_typeof(fact) <> 'object'
        OR NOT fact ?& ARRAY['statement_fr', 'evidence_ids']
        OR (SELECT count(*) FROM jsonb_object_keys(fact)) <> 2
        OR jsonb_typeof(fact->'statement_fr') <> 'string'
        OR length(fact->>'statement_fr') NOT BETWEEN 1 AND 240
        OR jsonb_typeof(fact->'evidence_ids') <> 'array'
        OR jsonb_array_length(fact->'evidence_ids') NOT BETWEEN 1 AND 10
        OR EXISTS (
          SELECT 1
          FROM jsonb_array_elements(fact->'evidence_ids') AS evidence_id
          WHERE jsonb_typeof(evidence_id) <> 'string'
            OR (evidence_id #>> '{}') !~ '^evidence-[0-9]{1,2}$'
        )
    )
    AND jsonb_typeof(output_payload->'uncertainties') = 'array'
    AND jsonb_array_length(output_payload->'uncertainties') <= 5
    AND NOT EXISTS (
      SELECT 1
      FROM jsonb_array_elements(output_payload->'uncertainties') AS uncertainty
      WHERE jsonb_typeof(uncertainty) <> 'string'
        OR length(uncertainty #>> '{}') NOT BETWEEN 1 AND 200
    )
    AND output_payload->>'disclaimer'
      = 'Déclaration criminelle non vérifiée ; aucune compromission n’est confirmée.'
    AND concat_ws(
      ' ',
      output_payload->>'summary_fr',
      output_payload->'observed_facts'::text,
      output_payload->'uncertainties'::text
    ) !~* 'https?://|confidence_score|verification_status|auto_alert_eligible|compromission\s+(est\s+)?confirmée|incident\s+(est\s+)?confirmé';
$$;

CREATE OR REPLACE FUNCTION build_claim_analysis_input(claim_record_id uuid)
RETURNS jsonb
LANGUAGE sql
STABLE
STRICT
AS $$
  WITH claim_record AS (
    SELECT claim.*
    FROM claims AS claim
    WHERE claim.id = claim_record_id
  ), ranked_observations AS (
    SELECT
      observation.id,
      source.name AS source_name,
      observation.published_at,
      observation.discovered_at,
      observation.description,
      row_number() OVER (
        ORDER BY
          coalesce(observation.published_at, observation.discovered_at, observation.fetched_at),
          observation.id
      ) AS evidence_number
    FROM claim_observations AS link
    JOIN observations AS observation ON observation.id = link.observation_id
    JOIN sources AS source ON source.id = observation.source_id
    WHERE link.claim_id = claim_record_id
    ORDER BY
      coalesce(observation.published_at, observation.discovered_at, observation.fetched_at),
      observation.id
    LIMIT 10
  ), evidence AS (
    SELECT coalesce(
      jsonb_agg(
        jsonb_build_object(
          'evidence_id', 'evidence-' || ranked_observations.evidence_number,
          'source_name', left(ranked_observations.source_name, 200),
          'published_at', ranked_observations.published_at,
          'discovered_at', ranked_observations.discovered_at,
          'description', CASE
            WHEN ranked_observations.description IS NULL THEN NULL
            ELSE left(ranked_observations.description, 1000)
          END
        )
        ORDER BY ranked_observations.evidence_number
      ),
      '[]'::jsonb
    ) AS observations
    FROM ranked_observations
  )
  SELECT jsonb_build_object(
    'claim', jsonb_build_object(
      'victim_name', left(claim_record.victim_name, 300),
      'threat_actor', CASE
        WHEN claim_record.threat_actor IS NULL THEN NULL
        ELSE left(claim_record.threat_actor, 200)
      END,
      'claimed_at', claim_record.claimed_at,
      'first_seen_at', claim_record.first_seen_at,
      'last_seen_at', claim_record.last_seen_at
    ),
    'observations', evidence.observations
  )
  FROM claim_record, evidence;
$$;

CREATE OR REPLACE FUNCTION get_pending_claim_analysis_jobs(
  requested_prompt_version text,
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
  IF requested_prompt_version <> 'claim-analysis-v1' THEN
    RAISE EXCEPTION 'unsupported analysis prompt version';
  END IF;
  IF requested_limit NOT BETWEEN 1 AND 50 THEN
    RAISE EXCEPTION 'analysis job limit must be between 1 and 50';
  END IF;

  RETURN QUERY
  WITH eligible AS (
    SELECT DISTINCT claim.id, claim.evidence_version, claim.updated_at
    FROM claims AS claim
    JOIN organization_matches AS match ON match.claim_id = claim.id
    WHERE match.review_status IN ('auto_accepted', 'accepted')
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
    )
  ORDER BY hashed.updated_at, hashed.id
  LIMIT requested_limit;
END;
$$;

CREATE OR REPLACE FUNCTION persist_claim_analysis_result(result_payload jsonb)
RETURNS TABLE (
  analysis_id uuid,
  created boolean,
  validation_status text,
  error_message text
)
LANGUAGE plpgsql
AS $$
DECLARE
  resolved_claim_id uuid;
  resolved_evidence_version integer;
  resolved_model_name text;
  resolved_model_digest text;
  resolved_prompt_version text;
  resolved_input_payload jsonb;
  resolved_input_hash text;
  resolved_output_payload jsonb;
  resolved_validation_status text;
  failure_code text;
  sanitized_error text;
  resolved_analysis_id uuid;
  created_record boolean := false;
  allowed_evidence_ids text[];
BEGIN
  IF jsonb_typeof(result_payload) <> 'object' THEN
    RAISE EXCEPTION 'analysis result envelope must be an object';
  END IF;

  resolved_claim_id := (result_payload->>'claim_id')::uuid;
  resolved_evidence_version := (result_payload->>'evidence_version')::integer;
  resolved_model_name := nullif(result_payload->>'model_name', '');
  resolved_model_digest := nullif(result_payload->>'model_digest', '');
  resolved_prompt_version := result_payload->>'prompt_version';
  resolved_input_payload := result_payload->'input_payload';
  resolved_input_hash := result_payload->>'input_hash';
  resolved_output_payload := result_payload->'output_payload';
  resolved_validation_status := result_payload->>'validation_status';
  failure_code := nullif(result_payload->>'failure_code', '');

  IF resolved_prompt_version <> 'claim-analysis-v1'
    OR resolved_model_name IS NULL
    OR resolved_evidence_version < 1
    OR resolved_input_payload IS NULL
    OR jsonb_typeof(resolved_input_payload) <> 'object'
    OR resolved_input_hash !~ '^[a-f0-9]{64}$'
    OR encode(digest(resolved_input_payload::text, 'sha256'), 'hex') <> resolved_input_hash
  THEN
    RAISE EXCEPTION 'invalid analysis provenance';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM claims
    WHERE id = resolved_claim_id
      AND evidence_version >= resolved_evidence_version
  ) THEN
    RAISE EXCEPTION 'analysis claim or evidence version not found';
  END IF;

  IF NOT validate_claim_analysis_output(resolved_output_payload) THEN
    RAISE EXCEPTION 'analysis output failed database validation';
  END IF;

  SELECT coalesce(array_agg(item->>'evidence_id'), ARRAY[]::text[])
  INTO allowed_evidence_ids
  FROM jsonb_array_elements(resolved_input_payload->'observations') AS item;

  IF EXISTS (
    SELECT 1
    FROM jsonb_array_elements(resolved_output_payload->'observed_facts') AS fact
    CROSS JOIN LATERAL jsonb_array_elements_text(fact->'evidence_ids') AS evidence_id
    WHERE NOT (evidence_id = ANY(allowed_evidence_ids))
  ) THEN
    RAISE EXCEPTION 'analysis output references unknown evidence';
  END IF;

  sanitized_error := CASE failure_code
    WHEN 'ollama_unavailable' THEN 'local analysis service unavailable; deterministic fallback stored'
    WHEN 'model_timeout' THEN 'local analysis timed out; deterministic fallback stored'
    WHEN 'model_output_invalid' THEN 'local analysis output invalid; deterministic fallback stored'
    WHEN 'model_digest_mismatch' THEN 'local model digest mismatch; deterministic fallback stored'
    ELSE NULL
  END;

  IF resolved_validation_status = 'valid' AND failure_code IS NOT NULL THEN
    RAISE EXCEPTION 'valid analysis cannot contain a failure code';
  ELSIF resolved_validation_status = 'fallback' AND sanitized_error IS NULL THEN
    RAISE EXCEPTION 'fallback analysis requires an allow-listed failure code';
  ELSIF resolved_validation_status NOT IN ('valid', 'fallback') THEN
    RAISE EXCEPTION 'unsupported analysis validation status';
  END IF;

  INSERT INTO analyses (
    claim_id,
    model_name,
    model_digest,
    prompt_version,
    input_hash,
    input_payload,
    evidence_version,
    output_payload,
    validation_status,
    error_message,
    inference_metadata
  )
  VALUES (
    resolved_claim_id,
    resolved_model_name,
    resolved_model_digest,
    resolved_prompt_version,
    resolved_input_hash,
    resolved_input_payload,
    resolved_evidence_version,
    resolved_output_payload,
    resolved_validation_status,
    sanitized_error,
    jsonb_strip_nulls(jsonb_build_object(
      'done_reason', result_payload#>>'{inference_metadata,done_reason}',
      'prompt_tokens', (result_payload#>>'{inference_metadata,prompt_tokens}')::integer,
      'output_tokens', (result_payload#>>'{inference_metadata,output_tokens}')::integer,
      'total_duration_ns', (result_payload#>>'{inference_metadata,total_duration_ns}')::bigint
    ))
  )
  ON CONFLICT (claim_id, prompt_version, input_hash) DO NOTHING
  RETURNING id INTO resolved_analysis_id;

  IF resolved_analysis_id IS NULL THEN
    SELECT analysis.id
    INTO resolved_analysis_id
    FROM analyses AS analysis
    WHERE analysis.claim_id = resolved_claim_id
      AND analysis.prompt_version = resolved_prompt_version
      AND analysis.input_hash = resolved_input_hash;
  ELSE
    created_record := true;
  END IF;

  RETURN QUERY
  SELECT resolved_analysis_id, created_record, resolved_validation_status, sanitized_error;
END;
$$;

INSERT INTO schema_migrations (version)
VALUES ('010_local_analysis_provenance')
ON CONFLICT (version) DO NOTHING;

COMMIT;
