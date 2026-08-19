\set ON_ERROR_STOP on

BEGIN;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM analysis_provider_configs
    WHERE provider = 'microsoft_foundry'
      AND enabled = false
  ) THEN
    RAISE EXCEPTION 'Foundry configuration must be seeded disabled';
  END IF;
  IF EXISTS (SELECT 1 FROM get_enabled_microsoft_foundry_config()) THEN
    RAISE EXCEPTION 'disabled Foundry configuration became active';
  END IF;
END;
$$;

UPDATE analysis_provider_configs
SET
  enabled = true,
  endpoint_base_url = 'https://synthetic-tcm.services.ai.azure.com',
  deployment_name = 'tcm-summary-cloud',
  model_name = 'approved-foundry-model',
  model_version = '2026-08-01',
  api_family = 'openai-v1',
  deployment_type = 'standard',
  data_processing_scope = 'regional-france-central',
  content_filter_name = 'tcm-default',
  updated_at = now()
WHERE provider = 'microsoft_foundry';

DO $$
DECLARE
  config record;
BEGIN
  SELECT * INTO config FROM get_enabled_microsoft_foundry_config();
  IF config.endpoint_base_url <> 'https://synthetic-tcm.services.ai.azure.com'
    OR config.deployment_name <> 'tcm-summary-cloud'
    OR config.api_family <> 'openai-v1'
    OR config.data_processing_scope <> 'regional-france-central'
  THEN
    RAISE EXCEPTION 'enabled Foundry configuration is incomplete';
  END IF;
END;
$$;

DO $$
BEGIN
  BEGIN
    UPDATE analysis_provider_configs
    SET endpoint_base_url = 'http://unsafe.example.invalid'
    WHERE provider = 'microsoft_foundry';
    RAISE EXCEPTION 'unsafe Foundry endpoint was accepted';
  EXCEPTION
    WHEN check_violation THEN NULL;
  END;

  BEGIN
    UPDATE analysis_provider_configs
    SET endpoint_base_url = 'https://synthetic-tcm.services.ai.azure.com/extra/path'
    WHERE provider = 'microsoft_foundry';
    RAISE EXCEPTION 'Foundry endpoint path was accepted';
  EXCEPTION
    WHEN check_violation THEN NULL;
  END;

  BEGIN
    UPDATE analysis_provider_configs
    SET endpoint_base_url = 'https://lookalike.services.ai.azure.com.evil.invalid'
    WHERE provider = 'microsoft_foundry';
    RAISE EXCEPTION 'Foundry endpoint lookalike was accepted';
  EXCEPTION
    WHEN check_violation THEN NULL;
  END;
END;
$$;

DO $$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'analysis_provider_configs'
      AND column_name ~* 'secret|token|key|credential|authorization'
  ) THEN
    RAISE EXCEPTION 'Foundry configuration table contains a secret-bearing column';
  END IF;
END;
$$;

ROLLBACK;

\echo 'Foundry provider configuration validation passed.'
