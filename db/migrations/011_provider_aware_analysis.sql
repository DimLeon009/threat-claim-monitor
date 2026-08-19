BEGIN;

ALTER TABLE analyses
  ADD COLUMN IF NOT EXISTS provider text NOT NULL DEFAULT 'ollama',
  ADD COLUMN IF NOT EXISTS deployment_name text,
  ADD COLUMN IF NOT EXISTS provider_metadata jsonb NOT NULL DEFAULT '{}'::jsonb;

UPDATE analyses
SET deployment_name = model_name
WHERE deployment_name IS NULL;

ALTER TABLE analyses
  ALTER COLUMN deployment_name SET NOT NULL,
  DROP CONSTRAINT IF EXISTS analyses_claim_id_prompt_version_input_hash_key,
  DROP CONSTRAINT IF EXISTS analyses_claim_prompt_input_provider_deployment_key,
  DROP CONSTRAINT IF EXISTS analyses_provider_check,
  DROP CONSTRAINT IF EXISTS analyses_provider_metadata_object_check;

ALTER TABLE analyses
  ADD CONSTRAINT analyses_provider_check
    CHECK (provider IN ('ollama', 'microsoft_foundry')),
  ADD CONSTRAINT analyses_provider_metadata_object_check
    CHECK (jsonb_typeof(provider_metadata) = 'object'),
  ADD CONSTRAINT analyses_claim_prompt_input_provider_deployment_key
    UNIQUE (claim_id, prompt_version, input_hash, provider, deployment_name);

CREATE OR REPLACE FUNCTION get_pending_claim_analysis_jobs(
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
        AND analysis.provider = requested_provider
        AND analysis.deployment_name = requested_deployment_name
    )
  ORDER BY hashed.updated_at, hashed.id
  LIMIT requested_limit;
END;
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
LANGUAGE sql
STABLE
AS $$
  SELECT *
  FROM get_pending_claim_analysis_jobs(
    requested_prompt_version,
    'ollama',
    'qwen3:8b-q4_K_M',
    requested_limit
  );
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
  resolved_provider text;
  resolved_deployment_name text;
  resolved_model_name text;
  resolved_model_digest text;
  resolved_provider_metadata jsonb;
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
  resolved_provider := coalesce(nullif(result_payload->>'provider', ''), 'ollama');
  resolved_model_name := nullif(result_payload->>'model_name', '');
  resolved_deployment_name := coalesce(
    nullif(result_payload->>'deployment_name', ''),
    resolved_model_name
  );
  resolved_model_digest := nullif(result_payload->>'model_digest', '');
  resolved_provider_metadata := coalesce(result_payload->'provider_metadata', '{}'::jsonb);
  resolved_prompt_version := result_payload->>'prompt_version';
  resolved_input_payload := result_payload->'input_payload';
  resolved_input_hash := result_payload->>'input_hash';
  resolved_output_payload := result_payload->'output_payload';
  resolved_validation_status := result_payload->>'validation_status';
  failure_code := nullif(result_payload->>'failure_code', '');

  IF resolved_prompt_version <> 'claim-analysis-v1'
    OR resolved_provider NOT IN ('ollama', 'microsoft_foundry')
    OR resolved_model_name IS NULL
    OR resolved_deployment_name IS NULL
    OR length(resolved_model_name) NOT BETWEEN 1 AND 200
    OR length(resolved_deployment_name) NOT BETWEEN 1 AND 200
    OR resolved_evidence_version < 1
    OR resolved_input_payload IS NULL
    OR jsonb_typeof(resolved_input_payload) <> 'object'
    OR resolved_input_hash !~ '^[a-f0-9]{64}$'
    OR encode(digest(resolved_input_payload::text, 'sha256'), 'hex') <> resolved_input_hash
    OR jsonb_typeof(resolved_provider_metadata) <> 'object'
    OR resolved_provider_metadata::text ~* 'secret|token|api[_-]?key|authorization|endpoint'
  THEN
    RAISE EXCEPTION 'invalid analysis provenance';
  END IF;

  IF resolved_provider = 'ollama'
    AND resolved_deployment_name <> resolved_model_name
  THEN
    RAISE EXCEPTION 'invalid Ollama deployment provenance';
  END IF;

  IF resolved_provider = 'microsoft_foundry' AND (
    NOT resolved_provider_metadata ?& ARRAY[
      'model_version',
      'api_family',
      'deployment_type',
      'data_processing_scope',
      'content_filter_name'
    ]
    OR (SELECT count(*) FROM jsonb_object_keys(resolved_provider_metadata)) <> 5
    OR resolved_provider_metadata->>'api_family' <> 'openai-v1'
    OR jsonb_typeof(resolved_provider_metadata->'model_version') <> 'string'
    OR jsonb_typeof(resolved_provider_metadata->'deployment_type') <> 'string'
    OR jsonb_typeof(resolved_provider_metadata->'data_processing_scope') <> 'string'
    OR jsonb_typeof(resolved_provider_metadata->'content_filter_name') <> 'string'
    OR length(resolved_provider_metadata->>'model_version') NOT BETWEEN 1 AND 100
    OR length(resolved_provider_metadata->>'deployment_type') NOT BETWEEN 1 AND 100
    OR length(resolved_provider_metadata->>'data_processing_scope') NOT BETWEEN 1 AND 100
    OR length(resolved_provider_metadata->>'content_filter_name') NOT BETWEEN 1 AND 200
  ) THEN
    RAISE EXCEPTION 'invalid Microsoft Foundry deployment provenance';
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
    WHEN 'model_timeout' THEN 'analysis timed out; deterministic fallback stored'
    WHEN 'model_output_invalid' THEN 'analysis output invalid; deterministic fallback stored'
    WHEN 'model_digest_mismatch' THEN 'local model digest mismatch; deterministic fallback stored'
    WHEN 'foundry_unavailable' THEN 'cloud analysis service unavailable; deterministic fallback stored'
    WHEN 'provider_rate_limited' THEN 'cloud analysis rate limited; deterministic fallback stored'
    WHEN 'provider_content_filtered' THEN 'cloud analysis content filtered; deterministic fallback stored'
    WHEN 'provider_authentication_failed' THEN 'cloud analysis authentication failed; deterministic fallback stored'
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
    provider,
    deployment_name,
    model_name,
    model_digest,
    provider_metadata,
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
    resolved_provider,
    resolved_deployment_name,
    resolved_model_name,
    resolved_model_digest,
    resolved_provider_metadata,
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
  ON CONFLICT (
    claim_id,
    prompt_version,
    input_hash,
    provider,
    deployment_name
  ) DO NOTHING
  RETURNING id INTO resolved_analysis_id;

  IF resolved_analysis_id IS NULL THEN
    SELECT analysis.id
    INTO resolved_analysis_id
    FROM analyses AS analysis
    WHERE analysis.claim_id = resolved_claim_id
      AND analysis.prompt_version = resolved_prompt_version
      AND analysis.input_hash = resolved_input_hash
      AND analysis.provider = resolved_provider
      AND analysis.deployment_name = resolved_deployment_name;
  ELSE
    created_record := true;
  END IF;

  RETURN QUERY
  SELECT resolved_analysis_id, created_record, resolved_validation_status, sanitized_error;
END;
$$;

INSERT INTO schema_migrations (version)
VALUES ('011_provider_aware_analysis')
ON CONFLICT (version) DO NOTHING;

COMMIT;
