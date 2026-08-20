BEGIN;

CREATE OR REPLACE VIEW source_health AS
SELECT
  source.id AS source_id,
  source.slug,
  source.name,
  source.enabled,
  source.poll_interval_minutes,
  latest_run.id AS latest_collection_run_id,
  latest_run.status AS latest_status,
  latest_run.started_at AS latest_started_at,
  latest_run.finished_at AS latest_finished_at,
  latest_run.fetched_count AS latest_fetched_count,
  latest_run.inserted_count AS latest_inserted_count,
  latest_run.metadata->>'contract_version' AS latest_contract_version,
  latest_run.metadata->>'failure_code' AS latest_failure_code,
  last_success.finished_at AS last_success_at,
  last_failure.finished_at AS last_failure_at,
  coalesce(consecutive_failures.failure_count, 0)::integer AS consecutive_failure_count,
  CASE
    WHEN latest_run.id IS NULL THEN 'not_observed'
    WHEN latest_run.metadata->>'failure_code' = 'response_validation_failed' THEN 'rejected'
    WHEN latest_run.status = 'succeeded' THEN 'accepted'
    ELSE 'not_observed'
  END AS latest_response_validation,
  CASE
    WHEN source.enabled = false THEN 'disabled'
    WHEN latest_run.id IS NULL THEN 'never_run'
    WHEN latest_run.status IN ('failed', 'partial')
      OR coalesce(consecutive_failures.failure_count, 0) > 0 THEN 'degraded'
    WHEN last_success.finished_at < clock_timestamp()
      - make_interval(mins => source.poll_interval_minutes * 3) THEN 'stale'
    ELSE 'healthy'
  END AS health_status
FROM sources AS source
LEFT JOIN LATERAL (
  SELECT run.*
  FROM collection_runs AS run
  WHERE run.source_id = source.id
  ORDER BY run.started_at DESC, run.id DESC
  LIMIT 1
) AS latest_run ON true
LEFT JOIN LATERAL (
  SELECT run.finished_at
  FROM collection_runs AS run
  WHERE run.source_id = source.id
    AND run.status = 'succeeded'
  ORDER BY run.finished_at DESC NULLS LAST, run.id DESC
  LIMIT 1
) AS last_success ON true
LEFT JOIN LATERAL (
  SELECT run.finished_at
  FROM collection_runs AS run
  WHERE run.source_id = source.id
    AND run.status IN ('failed', 'partial')
  ORDER BY run.finished_at DESC NULLS LAST, run.id DESC
  LIMIT 1
) AS last_failure ON true
LEFT JOIN LATERAL (
  SELECT count(*)::integer AS failure_count
  FROM collection_runs AS run
  WHERE run.source_id = source.id
    AND run.status IN ('failed', 'partial')
    AND (
      last_success.finished_at IS NULL
      OR run.started_at > last_success.finished_at
    )
) AS consecutive_failures ON true;

CREATE OR REPLACE FUNCTION set_source_enabled(
  requested_slug text,
  requested_enabled boolean,
  change_reason text
)
RETURNS TABLE (
  slug text,
  enabled boolean,
  changed boolean,
  updated_at timestamptz
)
LANGUAGE plpgsql
AS $$
DECLARE
  source_record sources%ROWTYPE;
  normalized_reason text := nullif(trim(change_reason), '');
  state_changed boolean;
BEGIN
  IF requested_slug IS NULL OR nullif(trim(requested_slug), '') IS NULL THEN
    RAISE EXCEPTION 'source slug is required';
  END IF;
  IF requested_enabled IS NULL THEN
    RAISE EXCEPTION 'source enabled state is required';
  END IF;
  IF normalized_reason IS NULL OR length(normalized_reason) > 200 THEN
    RAISE EXCEPTION 'source state change reason must contain between 1 and 200 characters';
  END IF;
  IF normalized_reason ~* 'https?://|api[_-]?key|authorization|bearer[[:space:]]|secret|token|password|credential' THEN
    RAISE EXCEPTION 'source state change reason contains prohibited secret-like material';
  END IF;

  SELECT *
  INTO source_record
  FROM sources AS source
  WHERE source.slug = trim(requested_slug)
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'source not found';
  END IF;

  state_changed := source_record.enabled IS DISTINCT FROM requested_enabled;

  UPDATE sources AS source
  SET enabled = requested_enabled,
      metadata = source.metadata || jsonb_build_object(
        'operational_state_changed_at', clock_timestamp(),
        'operational_state_change_reason', normalized_reason
      ),
      updated_at = clock_timestamp()
  WHERE source.id = source_record.id
  RETURNING source.slug, source.enabled, state_changed, source.updated_at
  INTO slug, enabled, changed, updated_at;

  RETURN NEXT;
END;
$$;

INSERT INTO schema_migrations (version)
VALUES ('021_source_health_and_switches')
ON CONFLICT (version) DO NOTHING;

COMMIT;
