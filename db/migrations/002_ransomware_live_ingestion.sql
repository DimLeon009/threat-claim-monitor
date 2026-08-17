BEGIN;

CREATE OR REPLACE FUNCTION ingest_ransomware_live_collection(records jsonb)
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
    RAISE EXCEPTION 'ransomware.live payload must be a JSON array';
  END IF;

  record_count := jsonb_array_length(records);
  IF record_count < 1 OR record_count > 500 THEN
    RAISE EXCEPTION 'ransomware.live payload size must be between 1 and 500 records';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM jsonb_array_elements(records) AS item
    WHERE jsonb_typeof(item) <> 'object'
      OR jsonb_typeof(item->'victim') <> 'string'
      OR jsonb_typeof(item->'group') <> 'string'
      OR jsonb_typeof(item->'discovered') <> 'string'
      OR nullif(trim(item->>'victim'), '') IS NULL
      OR nullif(trim(item->>'group'), '') IS NULL
      OR nullif(trim(item->>'discovered'), '') IS NULL
  ) THEN
    RAISE EXCEPTION 'ransomware.live payload contains an invalid required field';
  END IF;

  SELECT *
  INTO source_record
  FROM sources
  WHERE slug = 'ransomware-live' AND enabled = true
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'enabled ransomware-live source not found';
  END IF;

  baseline := NOT (source_record.metadata ? 'baseline_completed_at');

  INSERT INTO collection_runs (source_id, status, fetched_count, metadata)
  VALUES (
    source_record.id,
    'running',
    record_count,
    jsonb_build_object('contract_version', 'ransomware-live-v2-2026-08-14')
  )
  RETURNING id INTO run_id;

  WITH validated AS (
    SELECT
      trim(item->>'victim') AS victim_name,
      lower(trim(item->>'victim')) AS normalized_victim_name,
      nullif(lower(trim(item->>'domain')), '') AS victim_domain,
      trim(item->>'group') AS threat_actor,
      lower(trim(item->>'group')) AS normalized_threat_actor,
      nullif(trim(item->>'attackdate'), '')::timestamptz AS published_at,
      trim(item->>'discovered')::timestamptz AS discovered_at,
      nullif(trim(item->>'description'), '') AS description,
      coalesce(nullif(trim(item->>'url'), ''), nullif(trim(item->>'claim_url'), '')) AS source_url,
      jsonb_strip_nulls(jsonb_build_object(
        'activity', nullif(trim(item->>'activity'), ''),
        'attackdate', nullif(trim(item->>'attackdate'), ''),
        'claim_url', nullif(trim(item->>'claim_url'), ''),
        'country', nullif(trim(item->>'country'), ''),
        'description', nullif(trim(item->>'description'), ''),
        'discovered', trim(item->>'discovered'),
        'domain', nullif(trim(item->>'domain'), ''),
        'group', trim(item->>'group'),
        'url', nullif(trim(item->>'url'), ''),
        'victim', trim(item->>'victim')
      )) AS safe_payload
    FROM jsonb_array_elements(records) AS item
  ), inserted AS (
    INSERT INTO observations (
      source_id,
      collection_run_id,
      source_key,
      discovered_at,
      published_at,
      victim_name,
      normalized_victim_name,
      victim_domain,
      threat_actor,
      normalized_threat_actor,
      description,
      source_url,
      payload_hash,
      raw_payload,
      is_historical
    )
    SELECT
      source_record.id,
      run_id,
      encode(digest(
        normalized_victim_name || E'\n' || normalized_threat_actor || E'\n' || discovered_at::text,
        'sha256'
      ), 'hex'),
      discovered_at,
      published_at,
      victim_name,
      normalized_victim_name,
      victim_domain,
      threat_actor,
      normalized_threat_actor,
      description,
      source_url,
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

INSERT INTO schema_migrations (version)
VALUES ('002_ransomware_live_ingestion')
ON CONFLICT (version) DO NOTHING;

COMMIT;
