BEGIN;

CREATE TABLE IF NOT EXISTS analysis_provider_configs (
  provider text PRIMARY KEY CHECK (provider IN ('microsoft_foundry')),
  enabled boolean NOT NULL DEFAULT false,
  endpoint_base_url text,
  deployment_name text,
  model_name text,
  model_version text,
  api_family text,
  deployment_type text,
  data_processing_scope text,
  content_filter_name text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CHECK (
    endpoint_base_url IS NULL
    OR endpoint_base_url ~ '^https://[a-z0-9][a-z0-9-]{0,62}\.(openai\.azure\.com|services\.ai\.azure\.com)$'
  ),
  CHECK (
    enabled = false
    OR (
      endpoint_base_url IS NOT NULL
      AND length(deployment_name) BETWEEN 1 AND 200
      AND length(model_name) BETWEEN 1 AND 200
      AND length(model_version) BETWEEN 1 AND 100
      AND api_family = 'openai-v1'
      AND length(deployment_type) BETWEEN 1 AND 100
      AND length(data_processing_scope) BETWEEN 1 AND 100
      AND length(content_filter_name) BETWEEN 1 AND 200
    )
  )
);

INSERT INTO analysis_provider_configs (provider, enabled)
VALUES ('microsoft_foundry', false)
ON CONFLICT (provider) DO NOTHING;

CREATE OR REPLACE FUNCTION get_enabled_microsoft_foundry_config()
RETURNS TABLE (
  endpoint_base_url text,
  deployment_name text,
  model_name text,
  model_version text,
  api_family text,
  deployment_type text,
  data_processing_scope text,
  content_filter_name text
)
LANGUAGE sql
STABLE
AS $$
  SELECT
    config.endpoint_base_url,
    config.deployment_name,
    config.model_name,
    config.model_version,
    config.api_family,
    config.deployment_type,
    config.data_processing_scope,
    config.content_filter_name
  FROM analysis_provider_configs AS config
  WHERE config.provider = 'microsoft_foundry'
    AND config.enabled = true;
$$;

INSERT INTO schema_migrations (version)
VALUES ('012_foundry_provider_configuration')
ON CONFLICT (version) DO NOTHING;

COMMIT;
