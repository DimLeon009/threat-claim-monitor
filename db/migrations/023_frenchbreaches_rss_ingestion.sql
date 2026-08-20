BEGIN;

UPDATE sources
SET base_url = 'https://frenchbreaches.com/feed.xml',
    poll_interval_minutes = 240,
    metadata = (metadata - 'reason') || jsonb_build_object(
      'priority', 'experimental',
      'contract_version', 'frenchbreaches-rss-v1-2026-08-20',
      'repository_contract_status', 'validated',
      'retained_fields', jsonb_build_array('title', 'guid', 'link', 'published_at')
    ),
    updated_at = now()
WHERE slug = 'frenchbreaches';

CREATE OR REPLACE FUNCTION ingest_frenchbreaches_collection(records jsonb)
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
  rejected_count integer;
  new_count integer;
  baseline boolean;
BEGIN
  IF jsonb_typeof(records) <> 'array' THEN
    RAISE EXCEPTION 'FrenchBreaches payload must be a JSON array';
  END IF;

  record_count := jsonb_array_length(records);
  IF record_count < 1 OR record_count > 200 THEN
    RAISE EXCEPTION 'FrenchBreaches payload size must be between 1 and 200 records';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM jsonb_array_elements(records) AS item
    WHERE jsonb_typeof(item) <> 'object'
      OR jsonb_typeof(item->'title') <> 'string'
      OR jsonb_typeof(item->'guid') <> 'string'
      OR jsonb_typeof(item->'link') <> 'string'
      OR jsonb_typeof(item->'published_at') <> 'string'
      OR nullif(trim(item->>'title'), '') IS NULL
      OR nullif(trim(item->>'guid'), '') IS NULL
      OR nullif(trim(item->>'link'), '') IS NULL
      OR nullif(trim(item->>'published_at'), '') IS NULL
      OR length(trim(item->>'title')) > 200
      OR length(trim(item->>'guid')) > 1000
      OR length(trim(item->>'link')) > 1000
      OR length(trim(item->>'published_at')) > 40
      OR item->>'title' ~ '[[:cntrl:]]'
      OR item->>'guid' ~ '[[:cntrl:]]'
      OR item->>'link' ~ '[[:cntrl:]]'
      OR item->>'published_at' ~ '[[:cntrl:]]'
      OR trim(item->>'guid') <> trim(item->>'link')
      OR trim(item->>'link') !~ '^https://(www\.)?frenchbreaches\.com/'
      OR trim(item->>'published_at') !~ '^20[0-9]{2}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]{1,6})?Z$'
  ) THEN
    RAISE EXCEPTION 'FrenchBreaches payload contains an invalid required field';
  END IF;

  SELECT count(*)::integer
  INTO rejected_count
  FROM jsonb_array_elements(records) AS item
  WHERE normalize_match_text(item->>'title') IS NULL;

  IF rejected_count = record_count THEN
    RAISE EXCEPTION 'FrenchBreaches payload contains no usable observation';
  END IF;

  SELECT *
  INTO source_record
  FROM sources
  WHERE slug = 'frenchbreaches' AND enabled = true
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'enabled FrenchBreaches source not found';
  END IF;

  baseline := NOT (source_record.metadata ? 'baseline_completed_at');

  INSERT INTO collection_runs (source_id, status, fetched_count, metadata)
  VALUES (
    source_record.id,
    'running',
    record_count,
    jsonb_build_object(
      'contract_version', 'frenchbreaches-rss-v1-2026-08-20',
      'rejected_unmatchable_count', rejected_count
    )
  )
  RETURNING id INTO run_id;

  WITH validated AS (
    SELECT
      trim(item->>'title') AS victim_name,
      normalize_match_text(item->>'title') AS normalized_victim_name,
      trim(item->>'guid') AS source_guid,
      trim(item->>'link') AS source_link,
      trim(item->>'published_at')::timestamptz AS source_published_at,
      jsonb_build_object(
        'guid', trim(item->>'guid'),
        'link', trim(item->>'link'),
        'published_at', trim(item->>'published_at'),
        'title', trim(item->>'title')
      ) AS safe_payload
    FROM jsonb_array_elements(records) AS item
  ), inserted AS (
    INSERT INTO observations (
      source_id,
      collection_run_id,
      source_event_id,
      source_key,
      discovered_at,
      published_at,
      victim_name,
      normalized_victim_name,
      title,
      source_url,
      payload_hash,
      raw_payload,
      is_historical
    )
    SELECT
      source_record.id,
      run_id,
      source_guid,
      encode(digest(source_guid, 'sha256'), 'hex'),
      source_published_at,
      source_published_at,
      victim_name,
      normalized_victim_name,
      victim_name,
      source_link,
      encode(digest(safe_payload::text, 'sha256'), 'hex'),
      safe_payload,
      baseline
    FROM validated
    WHERE normalized_victim_name IS NOT NULL
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

CREATE OR REPLACE FUNCTION record_frenchbreaches_failure(failure_code text)
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
    WHEN 'fetch_failed' THEN 'FrenchBreaches RSS request failed after bounded retries'
    WHEN 'response_validation_failed' THEN 'FrenchBreaches RSS response rejected by contract validation'
    WHEN 'ingestion_failed' THEN 'FrenchBreaches database ingestion failed'
    ELSE NULL
  END;

  IF sanitized_message IS NULL THEN
    RAISE EXCEPTION 'unsupported FrenchBreaches failure code';
  END IF;

  SELECT id
  INTO source_record_id
  FROM sources
  WHERE slug = 'frenchbreaches' AND enabled = true;

  IF source_record_id IS NULL THEN
    RAISE EXCEPTION 'enabled FrenchBreaches source not found';
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
      'contract_version', 'frenchbreaches-rss-v1-2026-08-20',
      'failure_code', failure_code
    )
  )
  RETURNING id INTO run_id;

  RETURN QUERY
  SELECT run_id, 'failed'::text, sanitized_message;
END;
$$;

INSERT INTO schema_migrations (version)
VALUES ('023_frenchbreaches_rss_ingestion')
ON CONFLICT (version) DO NOTHING;

COMMIT;
