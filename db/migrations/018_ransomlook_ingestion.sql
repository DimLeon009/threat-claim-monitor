BEGIN;

CREATE OR REPLACE FUNCTION ingest_ransomlook_collection(records jsonb)
RETURNS TABLE (
  collection_run_id uuid,
  fetched_count integer,
  inserted_count integer,
  is_baseline boolean
)
LANGUAGE plpgsql
AS $$
DECLARE
  source_record sources%ROWTYPE;
  run_id uuid;
  record_count integer;
  new_count integer;
  baseline boolean;
BEGIN
  IF jsonb_typeof(records) <> 'array' THEN
    RAISE EXCEPTION 'RansomLook payload must be a JSON array';
  END IF;

  record_count := jsonb_array_length(records);
  IF record_count < 1 OR record_count > 500 THEN
    RAISE EXCEPTION 'RansomLook payload size must be between 1 and 500 records';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM jsonb_array_elements(records) AS item
    WHERE jsonb_typeof(item) <> 'object'
      OR jsonb_typeof(item->'post_title') <> 'string'
      OR jsonb_typeof(item->'group_name') <> 'string'
      OR jsonb_typeof(item->'discovered') <> 'string'
      OR nullif(trim(item->>'post_title'), '') IS NULL
      OR nullif(trim(item->>'group_name'), '') IS NULL
      OR nullif(trim(item->>'discovered'), '') IS NULL
  ) THEN
    RAISE EXCEPTION 'RansomLook payload contains an invalid required field';
  END IF;

  SELECT *
  INTO source_record
  FROM sources
  WHERE slug = 'ransomlook' AND enabled = true
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'enabled RansomLook source not found';
  END IF;

  baseline := NOT (source_record.metadata ? 'baseline_completed_at');

  INSERT INTO collection_runs (source_id, status, fetched_count, metadata)
  VALUES (
    source_record.id,
    'running',
    record_count,
    jsonb_build_object('contract_version', 'ransomlook-posts-v1-2026-08-19')
  )
  RETURNING id INTO run_id;

  WITH validated AS (
    SELECT
      trim(item->>'post_title') AS victim_name,
      normalize_match_text(item->>'post_title') AS normalized_victim_name,
      normalize_domain(item->>'post_title') AS victim_domain,
      trim(item->>'group_name') AS threat_actor,
      normalize_threat_actor(item->>'group_name') AS normalized_threat_actor,
      trim(item->>'discovered')::timestamptz AS discovered_at,
      jsonb_build_object(
        'discovered', trim(item->>'discovered'),
        'group_name', trim(item->>'group_name'),
        'post_title', trim(item->>'post_title')
      ) AS safe_payload
    FROM jsonb_array_elements(records) AS item
  ), inserted AS (
    INSERT INTO observations (
      source_id,
      collection_run_id,
      source_key,
      discovered_at,
      victim_name,
      normalized_victim_name,
      victim_domain,
      threat_actor,
      normalized_threat_actor,
      payload_hash,
      raw_payload,
      is_historical
    )
    SELECT
      source_record.id,
      run_id,
      encode(digest(
        normalized_victim_name || E'\n' || normalized_threat_actor || E'\n'
          || extract(epoch FROM discovered_at)::text,
        'sha256'
      ), 'hex'),
      discovered_at,
      victim_name,
      normalized_victim_name,
      victim_domain,
      threat_actor,
      normalized_threat_actor,
      encode(digest(safe_payload::text, 'sha256'), 'hex'),
      safe_payload,
      baseline
    FROM validated
    ON CONFLICT (source_id, source_key) DO NOTHING
    RETURNING 1
  )
  SELECT count(*)::integer INTO new_count FROM inserted;

  IF baseline THEN
    UPDATE sources
    SET metadata = metadata || jsonb_build_object('baseline_completed_at', now()),
        updated_at = now()
    WHERE id = source_record.id;
  END IF;

  UPDATE collection_runs
  SET finished_at = now(),
      status = 'succeeded',
      inserted_count = new_count,
      metadata = metadata || jsonb_build_object('is_baseline', baseline)
  WHERE id = run_id;

  RETURN QUERY SELECT run_id, record_count, new_count, baseline;
END;
$$;

CREATE OR REPLACE FUNCTION record_ransomlook_failure(failure_code text)
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
    WHEN 'fetch_failed' THEN 'RansomLook request failed after bounded retries'
    WHEN 'response_validation_failed' THEN 'RansomLook response rejected by contract validation'
    WHEN 'ingestion_failed' THEN 'RansomLook database ingestion failed'
    ELSE NULL
  END;

  IF sanitized_message IS NULL THEN
    RAISE EXCEPTION 'unsupported RansomLook failure code';
  END IF;

  SELECT id
  INTO source_record_id
  FROM sources
  WHERE slug = 'ransomlook' AND enabled = true;

  IF source_record_id IS NULL THEN
    RAISE EXCEPTION 'enabled RansomLook source not found';
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
      'contract_version', 'ransomlook-posts-v1-2026-08-19',
      'failure_code', failure_code
    )
  )
  RETURNING id INTO run_id;

  RETURN QUERY
  SELECT run_id, 'failed'::text, sanitized_message;
END;
$$;

INSERT INTO schema_migrations (version)
VALUES ('018_ransomlook_ingestion')
ON CONFLICT (version) DO NOTHING;

COMMIT;
