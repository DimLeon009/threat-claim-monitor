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
  source_slug text;
  observation_record record;
  correlation_result record;
  processed_count integer := 0;
  skipped_unmatchable_count integer := 0;
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
    AND source.enabled = true
  FOR UPDATE OF run;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'enabled source collection run not found';
  END IF;

  SELECT source.slug
  INTO source_slug
  FROM sources AS source
  WHERE source.id = run_record.source_id;

  IF run_record.status NOT IN ('succeeded', 'partial') THEN
    RAISE EXCEPTION 'collection run is not eligible for correlation';
  END IF;

  SELECT count(*)::integer
  INTO skipped_unmatchable_count
  FROM observations AS observation
  WHERE observation.collection_run_id = run_record.id
    AND normalize_match_text(observation.victim_name) IS NULL;

  FOR observation_record IN
    SELECT observation.id
    FROM observations AS observation
    WHERE observation.collection_run_id = run_record.id
      AND normalize_match_text(observation.victim_name) IS NOT NULL
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
      metadata = (run.metadata - 'correlation_failure_code' - 'correlation_failed_at')
        || jsonb_build_object(
          'correlation_status', 'succeeded',
          'correlation_source_slug', source_slug,
          'correlation_processed_count', processed_count,
          'correlation_skipped_unmatchable_count', skipped_unmatchable_count,
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

INSERT INTO schema_migrations (version)
VALUES ('022_skip_unmatchable_correlation_observations')
ON CONFLICT (version) DO NOTHING;

COMMIT;
