\set ON_ERROR_STOP on

BEGIN;

INSERT INTO claims (
  id, canonical_key, victim_name, normalized_victim_name, threat_actor,
  normalized_threat_actor, first_seen_at, last_seen_at
)
VALUES (
  '70000000-0000-4000-8000-000000000001',
  'synthetic-analysis-claim', 'Example Analysis Victim', 'example analysis victim',
  'Example Actor', 'example actor', '2026-08-18T08:00:00Z', '2026-08-18T08:10:00Z'
), (
  '70000000-0000-4000-8000-000000000002',
  'synthetic-analysis-fallback-claim', 'Example Fallback Victim', 'example fallback victim',
  'Example Actor', 'example actor', '2026-08-18T09:00:00Z', '2026-08-18T09:00:00Z'
);

INSERT INTO observations (
  id, source_id, source_key, discovered_at, victim_name, normalized_victim_name,
  threat_actor, normalized_threat_actor, description, payload_hash, raw_payload,
  is_historical
)
VALUES
  (
    '70000000-0000-4000-8000-000000000011',
    '10000000-0000-4000-8000-000000000001', 'synthetic-analysis-observation-1',
    '2026-08-18T08:00:00Z', 'Example Analysis Victim', 'example analysis victim',
    'Example Actor', 'example actor', 'Synthetic public description.', repeat('d', 64), '{}', false
  ),
  (
    '70000000-0000-4000-8000-000000000012',
    '10000000-0000-4000-8000-000000000001', 'synthetic-analysis-observation-2',
    '2026-08-18T08:10:00Z', 'Example Analysis Victim', 'example analysis victim',
    'Example Actor', 'example actor', NULL, repeat('e', 64), '{}', false
  ),
  (
    '70000000-0000-4000-8000-000000000013',
    '10000000-0000-4000-8000-000000000001', 'synthetic-analysis-observation-fallback',
    '2026-08-18T09:00:00Z', 'Example Fallback Victim', 'example fallback victim',
    'Example Actor', 'example actor', 'Synthetic fallback description.', repeat('f', 64), '{}', false
  );

INSERT INTO claim_observations (claim_id, observation_id)
VALUES
  ('70000000-0000-4000-8000-000000000001', '70000000-0000-4000-8000-000000000011'),
  ('70000000-0000-4000-8000-000000000001', '70000000-0000-4000-8000-000000000012'),
  ('70000000-0000-4000-8000-000000000002', '70000000-0000-4000-8000-000000000013');

INSERT INTO organization_matches (
  claim_id, organization_id, matching_method, confidence_score, review_status, evidence
)
VALUES (
  '70000000-0000-4000-8000-000000000001',
  '20000000-0000-4000-8000-000000000001',
  'domain_exact', 100, 'auto_accepted',
  '{"rule_version":"synthetic-analysis-test","auto_alert_eligible":true}'
), (
  '70000000-0000-4000-8000-000000000002',
  '20000000-0000-4000-8000-000000000001',
  'domain_exact', 100, 'auto_accepted',
  '{"rule_version":"synthetic-analysis-test","auto_alert_eligible":true}'
);

DO $$
DECLARE
  job record;
  output_payload jsonb;
  envelope jsonb;
  first_result record;
  replay_result record;
BEGIN
  SELECT * INTO job
  FROM get_pending_claim_analysis_jobs('claim-analysis-v1', 10)
  WHERE claim_id = '70000000-0000-4000-8000-000000000001';

  IF job.claim_id IS NULL
    OR job.input_hash !~ '^[a-f0-9]{64}$'
    OR jsonb_array_length(job.input_payload->'observations') <> 2
    OR job.input_payload#>>'{observations,0,evidence_id}' <> 'evidence-1'
    OR length(job.input_payload::text) > 12000
  THEN
    RAISE EXCEPTION 'eligible analysis job has invalid bounded provenance';
  END IF;

  output_payload := jsonb_build_object(
    'language', 'fr',
    'summary_fr', 'Deux observations synthétiques relaient une déclaration non vérifiée.',
    'observed_facts', jsonb_build_array(jsonb_build_object(
      'statement_fr', 'Deux observations publiques sont disponibles.',
      'evidence_ids', jsonb_build_array('evidence-1', 'evidence-2')
    )),
    'uncertainties', jsonb_build_array('La date de publication n’est pas renseignée.'),
    'disclaimer', 'Déclaration criminelle non vérifiée ; aucune compromission n’est confirmée.'
  );

  envelope := jsonb_build_object(
    'claim_id', job.claim_id,
    'evidence_version', job.evidence_version,
    'model_name', 'qwen3:8b-q4_K_M',
    'model_digest', '500a1f067a9f782620b40bee6f7b0c89e17ae61f686b92c24933e4ca4b2b8b41',
    'prompt_version', 'claim-analysis-v1',
    'input_payload', job.input_payload,
    'input_hash', job.input_hash,
    'output_payload', output_payload,
    'validation_status', 'valid',
    'inference_metadata', jsonb_build_object(
      'done_reason', 'stop', 'prompt_tokens', 100, 'output_tokens', 50, 'total_duration_ns', 123456
    )
  );

  SELECT * INTO first_result FROM persist_claim_analysis_result(envelope);
  SELECT * INTO replay_result FROM persist_claim_analysis_result(envelope);
  IF first_result.created IS DISTINCT FROM true
    OR replay_result.created IS DISTINCT FROM false
    OR first_result.analysis_id IS DISTINCT FROM replay_result.analysis_id
  THEN
    RAISE EXCEPTION 'analysis persistence must be idempotent';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM get_pending_claim_analysis_jobs('claim-analysis-v1', 10)
    WHERE claim_id = job.claim_id
  ) THEN
    RAISE EXCEPTION 'persisted input must leave the pending analysis queue';
  END IF;

  BEGIN
    PERFORM persist_claim_analysis_result(
      envelope || jsonb_build_object(
        'input_hash', repeat('0', 64),
        'prompt_version', 'claim-analysis-v1-bad'
      )
    );
    RAISE EXCEPTION 'invalid provenance was accepted';
  EXCEPTION
    WHEN raise_exception THEN
      IF SQLERRM = 'invalid provenance was accepted' THEN
        RAISE;
      END IF;
  END;
END;
$$;

DO $$
DECLARE
  job record;
  fallback_payload jsonb;
  stored_result record;
BEGIN
  SELECT * INTO job
  FROM get_pending_claim_analysis_jobs('claim-analysis-v1', 10)
  WHERE claim_id = '70000000-0000-4000-8000-000000000002';

  fallback_payload := jsonb_build_object(
    'language', 'fr',
    'summary_fr', 'Une ou plusieurs sources publiques relaient une déclaration concernant l’organisation surveillée. Les preuves disponibles ne confirment pas une compromission.',
    'observed_facts', '[]'::jsonb,
    'uncertainties', jsonb_build_array('Le service d’analyse locale n’a pas produit de sortie exploitable.'),
    'disclaimer', 'Déclaration criminelle non vérifiée ; aucune compromission n’est confirmée.'
  );

  SELECT * INTO stored_result
  FROM persist_claim_analysis_result(jsonb_build_object(
    'claim_id', job.claim_id,
    'evidence_version', job.evidence_version,
    'model_name', 'qwen3:8b-q4_K_M',
    'model_digest', '500a1f067a9f782620b40bee6f7b0c89e17ae61f686b92c24933e4ca4b2b8b41',
    'prompt_version', 'claim-analysis-v1',
    'input_payload', job.input_payload,
    'input_hash', job.input_hash,
    'output_payload', fallback_payload,
    'validation_status', 'fallback',
    'failure_code', 'model_output_invalid'
  ));

  IF stored_result.created IS DISTINCT FROM true
    OR stored_result.validation_status <> 'fallback'
    OR stored_result.error_message <> 'local analysis output invalid; deterministic fallback stored'
  THEN
    RAISE EXCEPTION 'fallback analysis was not stored with a sanitized failure';
  END IF;
END;
$$;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM analyses
    WHERE claim_id = '70000000-0000-4000-8000-000000000001'
      AND validation_status = 'valid'
      AND evidence_version = 1
      AND model_name = 'qwen3:8b-q4_K_M'
      AND model_digest = '500a1f067a9f782620b40bee6f7b0c89e17ae61f686b92c24933e4ca4b2b8b41'
      AND input_hash = encode(digest(input_payload::text, 'sha256'), 'hex')
      AND inference_metadata->>'done_reason' = 'stop'
  ) THEN
    RAISE EXCEPTION 'stored analysis provenance is incomplete';
  END IF;
END;
$$;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM analyses
    WHERE claim_id = '70000000-0000-4000-8000-000000000002'
      AND validation_status = 'fallback'
      AND error_message = 'local analysis output invalid; deterministic fallback stored'
      AND error_message NOT LIKE '%Synthetic fallback description%'
  ) THEN
    RAISE EXCEPTION 'stored fallback error is missing or unsafe';
  END IF;
END;
$$;

ROLLBACK;

\echo 'Local-analysis persistence validation passed.'
