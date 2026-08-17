BEGIN;

CREATE OR REPLACE FUNCTION correlate_collection_run_exact(collection_run_record_id uuid)
RETURNS TABLE (
  collection_run_id uuid,
  processed_observation_count integer,
  created_claim_count integer,
  created_link_count integer,
  persisted_match_count integer,
  auto_accepted_match_count integer
)
LANGUAGE plpgsql
AS $$
DECLARE
  run_record collection_runs%ROWTYPE;
  observation_record record;
  correlation_result record;
  processed_count integer := 0;
  claim_count integer := 0;
  link_count integer := 0;
  match_count integer := 0;
  accepted_match_count integer := 0;
BEGIN
  SELECT run.*
  INTO run_record
  FROM collection_runs AS run
  JOIN sources AS source ON source.id = run.source_id
  WHERE run.id = collection_run_record_id
    AND source.slug = 'ransomware-live'
  FOR UPDATE OF run;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'ransomware.live collection run not found';
  END IF;

  IF run_record.status NOT IN ('succeeded', 'partial') THEN
    RAISE EXCEPTION 'collection run is not eligible for correlation';
  END IF;

  FOR observation_record IN
    SELECT observation.id
    FROM observations AS observation
    WHERE observation.collection_run_id = run_record.id
    ORDER BY observation.created_at, observation.id
  LOOP
    SELECT *
    INTO correlation_result
    FROM correlate_observation_exact(observation_record.id);

    processed_count := processed_count + 1;
    claim_count := claim_count + correlation_result.claim_created::integer;
    link_count := link_count + correlation_result.observation_link_created::integer;
    match_count := match_count + correlation_result.persisted_match_count;
    accepted_match_count := accepted_match_count + correlation_result.auto_accepted_match_count;
  END LOOP;

  UPDATE collection_runs AS run
  SET status = 'succeeded',
      error_message = NULL,
      metadata = (run.metadata - 'correlation_failure_code') || jsonb_build_object(
        'correlation_status', 'succeeded',
        'correlation_processed_count', processed_count,
        'correlation_created_claim_count', claim_count,
        'correlation_created_link_count', link_count,
        'correlation_persisted_match_count', match_count,
        'correlation_auto_accepted_match_count', accepted_match_count,
        'correlation_completed_at', now()
      )
  WHERE run.id = run_record.id;

  RETURN QUERY
  SELECT
    run_record.id,
    processed_count,
    claim_count,
    link_count,
    match_count,
    accepted_match_count;
END;
$$;

CREATE OR REPLACE FUNCTION record_claim_correlation_failure(collection_run_record_id uuid)
RETURNS TABLE (
  collection_run_id uuid,
  status text,
  error_message text
)
LANGUAGE plpgsql
AS $$
DECLARE
  run_id uuid;
  sanitized_message text := 'claim correlation failed; retry the collection run correlation';
BEGIN
  UPDATE collection_runs AS run
  SET status = 'partial',
      error_message = sanitized_message,
      metadata = run.metadata || jsonb_build_object(
        'correlation_status', 'failed',
        'correlation_failure_code', 'correlation_failed',
        'correlation_failed_at', now()
      )
  FROM sources AS source
  WHERE run.id = collection_run_record_id
    AND source.id = run.source_id
    AND source.slug = 'ransomware-live'
    AND run.status IN ('succeeded', 'partial')
  RETURNING run.id INTO run_id;

  IF run_id IS NULL THEN
    RAISE EXCEPTION 'eligible ransomware.live collection run not found';
  END IF;

  RETURN QUERY
  SELECT run_id, 'partial'::text, sanitized_message;
END;
$$;

INSERT INTO schema_migrations (version)
VALUES ('007_collection_run_correlation')
ON CONFLICT (version) DO NOTHING;

COMMIT;
