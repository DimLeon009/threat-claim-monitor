BEGIN;

CREATE OR REPLACE FUNCTION record_ransomware_live_failure(failure_code text)
RETURNS TABLE (
  collection_run_id uuid,
  status text,
  error_message text
)
LANGUAGE plpgsql
AS $$
DECLARE
  source_record_id uuid;
  run_id uuid;
  sanitized_message text;
BEGIN
  sanitized_message := CASE failure_code
    WHEN 'fetch_failed' THEN 'ransomware.live request failed after bounded retries'
    WHEN 'response_validation_failed' THEN 'ransomware.live response rejected by contract validation'
    WHEN 'ingestion_failed' THEN 'ransomware.live database ingestion failed'
    ELSE NULL
  END;

  IF sanitized_message IS NULL THEN
    RAISE EXCEPTION 'unsupported ransomware.live failure code';
  END IF;

  SELECT id
  INTO source_record_id
  FROM sources
  WHERE slug = 'ransomware-live' AND enabled = true;

  IF source_record_id IS NULL THEN
    RAISE EXCEPTION 'enabled ransomware-live source not found';
  END IF;

  INSERT INTO collection_runs (
    source_id,
    finished_at,
    status,
    fetched_count,
    inserted_count,
    error_message,
    metadata
  )
  VALUES (
    source_record_id,
    now(),
    'failed',
    0,
    0,
    sanitized_message,
    jsonb_build_object(
      'contract_version', 'ransomware-live-v2-2026-08-14',
      'failure_code', failure_code
    )
  )
  RETURNING id INTO run_id;

  RETURN QUERY
  SELECT run_id, 'failed'::text, sanitized_message;
END;
$$;

INSERT INTO schema_migrations (version)
VALUES ('003_ransomware_live_failure_history')
ON CONFLICT (version) DO NOTHING;

COMMIT;
