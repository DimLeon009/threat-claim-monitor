\set ON_ERROR_STOP on

BEGIN;

CREATE TEMP TABLE demo_analysis_result (
  analysis_id uuid,
  created boolean,
  validation_status text,
  error_message text
) ON COMMIT DROP;

DO $$
DECLARE
  resolved_claim claims%ROWTYPE;
  resolved_input jsonb;
  resolved_input_hash text;
  resolved_evidence_id text;
  existing_analysis_id uuid;
  existing_validation_status text;
  existing_error_message text;
BEGIN
  SELECT claim.*
  INTO resolved_claim
  FROM collection_runs AS run
  JOIN claims AS claim ON claim.id = (run.metadata->>'demo_claim_id')::uuid
  WHERE run.id = '7d000000-0000-4000-8000-000000000010'
    AND run.metadata @> '{"synthetic":true,"fixture":"m6-end-to-end-v1"}'::jsonb;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'synthetic demo claim not found; run seed_end_to_end.sql first';
  END IF;

  SELECT analysis.id, analysis.validation_status, analysis.error_message
  INTO existing_analysis_id, existing_validation_status, existing_error_message
  FROM analyses AS analysis
  WHERE analysis.claim_id = resolved_claim.id
    AND analysis.evidence_version = resolved_claim.evidence_version
    AND analysis.validation_status IN ('valid', 'fallback')
  ORDER BY (analysis.validation_status = 'valid') DESC, analysis.created_at DESC
  LIMIT 1;

  IF FOUND THEN
    INSERT INTO demo_analysis_result VALUES (
      existing_analysis_id,
      false,
      existing_validation_status,
      existing_error_message
    );
    RETURN;
  END IF;

  resolved_input := build_claim_analysis_input(resolved_claim.id);
  resolved_input_hash := encode(digest(resolved_input::text, 'sha256'), 'hex');
  SELECT item->>'evidence_id'
  INTO resolved_evidence_id
  FROM jsonb_array_elements(resolved_input->'observations') AS item
  LIMIT 1;

  IF resolved_evidence_id IS NULL THEN
    RAISE EXCEPTION 'synthetic demo analysis input has no evidence';
  END IF;

  INSERT INTO demo_analysis_result
  SELECT *
  FROM persist_claim_analysis_result(jsonb_build_object(
    'claim_id', resolved_claim.id,
    'evidence_version', resolved_claim.evidence_version,
    'provider', 'ollama',
    'deployment_name', 'qwen3:8b-q4_K_M',
    'model_name', 'qwen3:8b-q4_K_M',
    'model_digest', NULL,
    'provider_metadata', '{}'::jsonb,
    'prompt_version', 'claim-analysis-v1',
    'input_payload', resolved_input,
    'input_hash', resolved_input_hash,
    'output_payload', jsonb_build_object(
      'language', 'fr',
      'summary_fr', U&'Une source synth\00E9tique signale une d\00E9claration de d\00E9monstration concernant une organisation fictive.',
      'observed_facts', jsonb_build_array(jsonb_build_object(
        'statement_fr', U&'Une observation synth\00E9tique M6 a travers\00E9 la corr\00E9lation d\00E9terministe.',
        'evidence_ids', jsonb_build_array(resolved_evidence_id)
      )),
      'uncertainties', jsonb_build_array(
        U&'Cette donn\00E9e est exclusivement synth\00E9tique et ne repr\00E9sente aucun incident r\00E9el.'
      ),
      'disclaimer', U&'D\00E9claration criminelle non v\00E9rifi\00E9e ; aucune compromission n\2019est confirm\00E9e.'
    ),
    'validation_status', 'fallback',
    'failure_code', 'ollama_unavailable',
    'inference_metadata', '{}'::jsonb
  ));
END;
$$;

DO $$
BEGIN
  IF (SELECT count(*) FROM demo_analysis_result) <> 1
    OR EXISTS (
      SELECT 1
      FROM demo_analysis_result
      WHERE validation_status NOT IN ('valid', 'fallback')
    )
  THEN
    RAISE EXCEPTION 'synthetic demo analysis was not stored';
  END IF;
END;
$$;

TABLE demo_analysis_result;

COMMIT;

\echo 'Synthetic M6 analysis contract passed.'
