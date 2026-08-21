\set ON_ERROR_STOP on

BEGIN;

UPDATE analysis_routing_policy
SET selected_provider = 'ollama',
    effective_from = '2000-01-01T00:00:00Z',
    change_reason = 'synthetic routing fixture',
    updated_at = clock_timestamp()
WHERE id = 1;

UPDATE analysis_provider_configs
SET enabled = true,
    endpoint_base_url = 'https://synthetic-routing.services.ai.azure.com',
    deployment_name = 'synthetic-foundry-deployment',
    model_name = 'synthetic-foundry-model',
    model_version = 'synthetic-v1',
    api_family = 'openai-v1',
    deployment_type = 'data-zone-standard',
    data_processing_scope = 'synthetic-data-zone',
    content_filter_name = 'synthetic-default',
    updated_at = clock_timestamp()
WHERE provider = 'microsoft_foundry';

INSERT INTO sources (
  id, slug, name, source_kind, base_url, enabled, poll_interval_minutes, metadata
)
VALUES (
  '8a100000-0000-4000-8000-000000000001',
  'synthetic-analysis-routing-source',
  'Synthetic Analysis Routing Source',
  'api', 'https://routing.invalid', true, 60,
  '{"fixture":"analysis-provider-routing"}'::jsonb
);

INSERT INTO claims (
  id, canonical_key, victim_name, normalized_victim_name,
  first_seen_at, last_seen_at, evidence_version, updated_at
)
VALUES (
  '8a100000-0000-4000-8000-000000000011',
  'synthetic-analysis-routing-claim',
  'Synthetic Routing Victim', 'synthetic routing victim',
  clock_timestamp(), clock_timestamp(), 1, clock_timestamp()
);

INSERT INTO observations (
  id, source_id, source_key, fetched_at, discovered_at,
  victim_name, normalized_victim_name, payload_hash, raw_payload, is_historical
)
VALUES (
  '8a100000-0000-4000-8000-000000000021',
  '8a100000-0000-4000-8000-000000000001',
  'synthetic-analysis-routing-observation',
  clock_timestamp(), clock_timestamp(),
  'Synthetic Routing Victim', 'synthetic routing victim',
  repeat('8', 64), '{"fixture":"analysis-provider-routing"}'::jsonb, false
);

INSERT INTO claim_observations (claim_id, observation_id)
VALUES (
  '8a100000-0000-4000-8000-000000000011',
  '8a100000-0000-4000-8000-000000000021'
);

INSERT INTO organization_matches (
  claim_id, organization_id, matching_method, confidence_score,
  review_status, evidence
)
VALUES (
  '8a100000-0000-4000-8000-000000000011',
  '20000000-0000-4000-8000-000000000001',
  'name_exact', 95, 'auto_accepted',
  '{"fixture":"analysis-provider-routing","auto_alert_eligible":true}'::jsonb
);

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM get_analysis_routing_decision()
    WHERE selected_provider = 'ollama'
      AND deployment_name = 'qwen3:8b-q4_K_M'
      AND route_ready = true
  ) THEN
    RAISE EXCEPTION 'default local analysis route is invalid';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM get_routed_pending_claim_analysis_jobs(
      'claim-analysis-v1', 'ollama', 'qwen3:8b-q4_K_M', 10
    ) WHERE claim_id = '8a100000-0000-4000-8000-000000000011'
  ) OR EXISTS (
    SELECT 1 FROM get_routed_pending_claim_analysis_jobs(
      'claim-analysis-v1', 'microsoft_foundry', 'synthetic-foundry-deployment', 10
    )
  ) THEN
    RAISE EXCEPTION 'local route did not isolate provider jobs';
  END IF;
END;
$$;

CREATE TEMP TABLE foundry_switch AS
SELECT * FROM set_analysis_routing_provider(
  'microsoft_foundry', 'synthetic reviewed cloud selection'
);

DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM foundry_switch WHERE changed = false
  ) OR EXISTS (
    SELECT 1 FROM get_routed_pending_claim_analysis_jobs(
      'claim-analysis-v1', 'microsoft_foundry', 'synthetic-foundry-deployment', 10
    )
  ) THEN
    RAISE EXCEPTION 'provider switch performed an implicit historical backfill';
  END IF;
END;
$$;

UPDATE claims
SET updated_at = clock_timestamp()
WHERE id = '8a100000-0000-4000-8000-000000000011';

CREATE TEMP TABLE repeated_foundry_switch AS
SELECT * FROM set_analysis_routing_provider(
  'microsoft_foundry', 'synthetic repeated reviewed selection'
);

DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM repeated_foundry_switch WHERE changed = true
  ) OR NOT EXISTS (
    SELECT 1 FROM get_routed_pending_claim_analysis_jobs(
      'claim-analysis-v1', 'microsoft_foundry', 'synthetic-foundry-deployment', 10
    ) WHERE claim_id = '8a100000-0000-4000-8000-000000000011'
  ) OR EXISTS (
    SELECT 1 FROM get_routed_pending_claim_analysis_jobs(
      'claim-analysis-v1', 'ollama', 'qwen3:8b-q4_K_M', 10
    )
  ) THEN
    RAISE EXCEPTION 'cloud route is not exclusive or idempotent';
  END IF;
END;
$$;

UPDATE analysis_provider_configs
SET enabled = false, updated_at = clock_timestamp()
WHERE provider = 'microsoft_foundry';

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM get_analysis_routing_decision()
    WHERE selected_provider = 'microsoft_foundry' AND route_ready = false
  ) OR EXISTS (
    SELECT 1 FROM get_routed_pending_claim_analysis_jobs(
      'claim-analysis-v1', 'microsoft_foundry', 'synthetic-foundry-deployment', 10
    )
  ) THEN
    RAISE EXCEPTION 'disabled Foundry route did not fail closed';
  END IF;

  BEGIN
    PERFORM * FROM set_analysis_routing_provider(
      'ollama', 'token=https://unsafe.invalid'
    );
    RAISE EXCEPTION 'unsafe routing reason was accepted';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'analysis routing reason contains prohibited secret-like material' THEN
      RAISE;
    END IF;
  END;
END;
$$;

ROLLBACK;

\echo 'Analysis provider routing runtime validation passed.'
