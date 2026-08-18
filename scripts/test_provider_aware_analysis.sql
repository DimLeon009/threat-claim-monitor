\set ON_ERROR_STOP on

BEGIN;

INSERT INTO claims (
  id, canonical_key, victim_name, normalized_victim_name, threat_actor,
  normalized_threat_actor, first_seen_at, last_seen_at
)
VALUES (
  '72000000-0000-4000-8000-000000000001',
  'synthetic-provider-aware-claim',
  'Example Provider Victim', 'example provider victim',
  'Example Provider Actor', 'example provider actor',
  '2026-08-18T12:00:00Z', '2026-08-18T12:00:00Z'
);

INSERT INTO observations (
  id, source_id, source_key, discovered_at, published_at,
  victim_name, normalized_victim_name, threat_actor, normalized_threat_actor,
  description, payload_hash, raw_payload, is_historical
)
VALUES (
  '72000000-0000-4000-8000-000000000011',
  '10000000-0000-4000-8000-000000000001',
  'synthetic-provider-aware-observation',
  '2026-08-18T12:00:00Z', '2026-08-18T11:55:00Z',
  'Example Provider Victim', 'example provider victim',
  'Example Provider Actor', 'example provider actor',
  'Synthetic public provider-comparison evidence.',
  repeat('9', 64), '{"fixture":"provider-aware-analysis"}'::jsonb, false
);

INSERT INTO claim_observations (claim_id, observation_id)
VALUES (
  '72000000-0000-4000-8000-000000000001',
  '72000000-0000-4000-8000-000000000011'
);

INSERT INTO organization_matches (
  claim_id, organization_id, matching_method, confidence_score, review_status, evidence
)
VALUES (
  '72000000-0000-4000-8000-000000000001',
  '20000000-0000-4000-8000-000000000001',
  'name_exact', 95, 'auto_accepted',
  '{"rule_version":"provider-aware-test","auto_alert_eligible":true}'::jsonb
);

DO $$
DECLARE
  local_job record;
  cloud_job record;
  output_payload jsonb;
  local_envelope jsonb;
  cloud_envelope jsonb;
  first_result record;
  replay_result record;
BEGIN
  SELECT * INTO local_job
  FROM get_pending_claim_analysis_jobs('claim-analysis-v1', 10)
  WHERE claim_id = '72000000-0000-4000-8000-000000000001';

  SELECT * INTO cloud_job
  FROM get_pending_claim_analysis_jobs(
    'claim-analysis-v1',
    'microsoft_foundry',
    'tcm-summary-cloud',
    10
  )
  WHERE claim_id = '72000000-0000-4000-8000-000000000001';

  IF local_job.claim_id IS NULL
    OR cloud_job.claim_id IS NULL
    OR local_job.input_hash IS DISTINCT FROM cloud_job.input_hash
  THEN
    RAISE EXCEPTION 'provider queues must expose the same bounded input independently';
  END IF;

  output_payload := jsonb_build_object(
    'language', 'fr',
    'summary_fr', 'Une source publique relaie une déclaration synthétique non vérifiée.',
    'observed_facts', jsonb_build_array(jsonb_build_object(
      'statement_fr', 'Une observation synthétique est disponible.',
      'evidence_ids', jsonb_build_array('evidence-1')
    )),
    'uncertainties', jsonb_build_array('La compromission n’est pas confirmée.'),
    'disclaimer', 'Déclaration criminelle non vérifiée ; aucune compromission n’est confirmée.'
  );

  local_envelope := jsonb_build_object(
    'claim_id', local_job.claim_id,
    'evidence_version', local_job.evidence_version,
    'model_name', 'qwen3:8b-q4_K_M',
    'model_digest', '500a1f067a9f782620b40bee6f7b0c89e17ae61f686b92c24933e4ca4b2b8b41',
    'prompt_version', 'claim-analysis-v1',
    'input_payload', local_job.input_payload,
    'input_hash', local_job.input_hash,
    'output_payload', output_payload,
    'validation_status', 'valid'
  );

  SELECT * INTO first_result FROM persist_claim_analysis_result(local_envelope);
  SELECT * INTO replay_result FROM persist_claim_analysis_result(local_envelope);
  IF first_result.created IS DISTINCT FROM true
    OR replay_result.created IS DISTINCT FROM false
    OR first_result.analysis_id IS DISTINCT FROM replay_result.analysis_id
  THEN
    RAISE EXCEPTION 'legacy Ollama persistence lost provider-aware idempotency';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM get_pending_claim_analysis_jobs('claim-analysis-v1', 10)
    WHERE claim_id = local_job.claim_id
  ) THEN
    RAISE EXCEPTION 'persisted Ollama input remained in the local queue';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM get_pending_claim_analysis_jobs(
      'claim-analysis-v1',
      'microsoft_foundry',
      'tcm-summary-cloud',
      10
    )
    WHERE claim_id = cloud_job.claim_id
  ) THEN
    RAISE EXCEPTION 'Ollama persistence incorrectly consumed the Foundry queue';
  END IF;

  cloud_envelope := jsonb_build_object(
    'claim_id', cloud_job.claim_id,
    'evidence_version', cloud_job.evidence_version,
    'provider', 'microsoft_foundry',
    'deployment_name', 'tcm-summary-cloud',
    'model_name', 'approved-foundry-model',
    'provider_metadata', jsonb_build_object(
      'model_version', '2026-08-01',
      'api_family', 'openai-v1',
      'deployment_type', 'standard',
      'data_processing_scope', 'regional-france-central',
      'content_filter_name', 'tcm-default'
    ),
    'prompt_version', 'claim-analysis-v1',
    'input_payload', cloud_job.input_payload,
    'input_hash', cloud_job.input_hash,
    'output_payload', output_payload,
    'validation_status', 'valid',
    'inference_metadata', jsonb_build_object(
      'done_reason', 'stop',
      'prompt_tokens', 900,
      'output_tokens', 120,
      'total_duration_ns', 2500000000
    )
  );

  BEGIN
    PERFORM persist_claim_analysis_result(
      cloud_envelope || jsonb_build_object('provider_metadata', '{}'::jsonb)
    );
    RAISE EXCEPTION 'incomplete Foundry provenance was accepted';
  EXCEPTION
    WHEN raise_exception THEN
      IF SQLERRM = 'incomplete Foundry provenance was accepted' THEN
        RAISE;
      END IF;
  END;

  SELECT * INTO first_result FROM persist_claim_analysis_result(cloud_envelope);
  SELECT * INTO replay_result FROM persist_claim_analysis_result(cloud_envelope);
  IF first_result.created IS DISTINCT FROM true
    OR replay_result.created IS DISTINCT FROM false
    OR first_result.analysis_id IS DISTINCT FROM replay_result.analysis_id
  THEN
    RAISE EXCEPTION 'Foundry persistence must be idempotent per deployment';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM get_pending_claim_analysis_jobs(
      'claim-analysis-v1',
      'microsoft_foundry',
      'tcm-summary-cloud',
      10
    )
    WHERE claim_id = cloud_job.claim_id
  ) THEN
    RAISE EXCEPTION 'persisted Foundry input remained in its deployment queue';
  END IF;

  SELECT * INTO first_result
  FROM persist_claim_analysis_result(
    cloud_envelope
      || jsonb_build_object(
        'deployment_name', 'tcm-summary-cloud-fallback',
        'validation_status', 'fallback',
        'failure_code', 'provider_rate_limited'
      )
  );
  IF first_result.created IS DISTINCT FROM true
    OR first_result.validation_status <> 'fallback'
    OR first_result.error_message <> 'cloud analysis rate limited; deterministic fallback stored'
  THEN
    RAISE EXCEPTION 'Foundry fallback was not stored with a sanitized failure';
  END IF;

  BEGIN
    PERFORM * FROM get_pending_claim_analysis_jobs(
      'claim-analysis-v1',
      'unsupported_provider',
      'test',
      10
    );
    RAISE EXCEPTION 'unsupported provider queue was accepted';
  EXCEPTION
    WHEN raise_exception THEN
      IF SQLERRM = 'unsupported provider queue was accepted' THEN
        RAISE;
      END IF;
  END;
END;
$$;

DO $$
BEGIN
  IF (SELECT count(*) FROM analyses
      WHERE claim_id = '72000000-0000-4000-8000-000000000001') <> 3
    OR (SELECT count(DISTINCT provider) FROM analyses
        WHERE claim_id = '72000000-0000-4000-8000-000000000001') <> 2
    OR NOT EXISTS (
      SELECT 1
      FROM analyses
      WHERE claim_id = '72000000-0000-4000-8000-000000000001'
        AND provider = 'ollama'
        AND deployment_name = 'qwen3:8b-q4_K_M'
        AND provider_metadata = '{}'::jsonb
    )
    OR NOT EXISTS (
      SELECT 1
      FROM analyses
      WHERE claim_id = '72000000-0000-4000-8000-000000000001'
        AND provider = 'microsoft_foundry'
        AND deployment_name = 'tcm-summary-cloud'
        AND provider_metadata->>'api_family' = 'openai-v1'
        AND provider_metadata->>'data_processing_scope' = 'regional-france-central'
        AND input_hash = encode(digest(input_payload::text, 'sha256'), 'hex')
    )
    OR EXISTS (
      SELECT 1
      FROM analyses
      WHERE claim_id = '72000000-0000-4000-8000-000000000001'
        AND provider_metadata::text ~* 'secret|token|api[_-]?key|authorization|endpoint'
    )
  THEN
    RAISE EXCEPTION 'stored multi-provider provenance is incomplete or unsafe';
  END IF;
END;
$$;

ROLLBACK;

\echo 'Provider-aware analysis validation passed.'
