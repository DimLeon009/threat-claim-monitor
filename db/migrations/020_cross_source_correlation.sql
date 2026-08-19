BEGIN;

CREATE OR REPLACE FUNCTION correlate_observation_exact(observation_record_id uuid)
RETURNS TABLE (
  claim_id uuid,
  claim_created boolean,
  observation_link_created boolean,
  evidence_version integer,
  persisted_match_count integer,
  auto_accepted_match_count integer
)
LANGUAGE plpgsql
AS $$
DECLARE
  core_result record;
  observation_record observations%ROWTYPE;
  distinct_source_count integer;
  final_match_count integer;
  final_auto_accepted_count integer;
BEGIN
  SELECT *
  INTO core_result
  FROM correlate_observation_exact_core(observation_record_id);

  SELECT *
  INTO observation_record
  FROM observations
  WHERE id = observation_record_id;

  PERFORM persist_review_organization_candidates(
    core_result.claim_id,
    observation_record.id,
    observation_record.victim_name,
    observation_record.victim_domain,
    core_result.evidence_version
  );

  SELECT count(DISTINCT linked_observation.source_id)::integer
  INTO distinct_source_count
  FROM claim_observations AS link
  JOIN observations AS linked_observation ON linked_observation.id = link.observation_id
  WHERE link.claim_id = core_result.claim_id;

  IF distinct_source_count >= 2 THEN
    UPDATE claims AS claim
    SET verification_status = 'multi_source_observed',
        updated_at = now()
    WHERE claim.id = core_result.claim_id
      AND claim.verification_status = 'claimed';
  END IF;

  SELECT
    count(*)::integer,
    count(*) FILTER (WHERE review_status = 'auto_accepted')::integer
  INTO final_match_count, final_auto_accepted_count
  FROM organization_matches AS match
  WHERE match.claim_id = core_result.claim_id;

  RETURN QUERY
  SELECT
    core_result.claim_id,
    core_result.claim_created,
    core_result.observation_link_created,
    core_result.evidence_version,
    final_match_count,
    final_auto_accepted_count;
END;
$$;

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
        'correlation_source_slug', source_slug,
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
    AND source.enabled = true
    AND run.status IN ('succeeded', 'partial')
  RETURNING run.id INTO run_id;

  IF run_id IS NULL THEN
    RAISE EXCEPTION 'eligible enabled-source collection run not found';
  END IF;

  RETURN QUERY
  SELECT run_id, 'partial'::text, sanitized_message;
END;
$$;

CREATE OR REPLACE FUNCTION enqueue_ready_claim_notifications(
  requested_limit integer DEFAULT 50
)
RETURNS TABLE (
  claim_id uuid,
  analysis_id uuid,
  notification_id uuid,
  channel text,
  created boolean
)
LANGUAGE plpgsql
AS $$
BEGIN
  IF requested_limit IS NULL OR requested_limit NOT BETWEEN 1 AND 100 THEN
    RAISE EXCEPTION 'notification producer limit must be between 1 and 100';
  END IF;

  RETURN QUERY
  WITH ranked_analyses AS (
    SELECT
      analysis.claim_id,
      analysis.id AS analysis_id,
      row_number() OVER (
        PARTITION BY analysis.claim_id
        ORDER BY
          CASE analysis.validation_status WHEN 'valid' THEN 0 ELSE 1 END,
          CASE
            WHEN analysis.provider = 'microsoft_foundry'
              AND EXISTS (
                SELECT 1
                FROM analysis_provider_configs AS provider_config
                WHERE provider_config.provider = 'microsoft_foundry'
                  AND provider_config.enabled = true
              ) THEN 0
            WHEN analysis.provider = 'ollama' THEN 1
            ELSE 2
          END,
          analysis.created_at DESC,
          analysis.id
      ) AS analysis_rank
    FROM analyses AS analysis
    JOIN claims AS claim ON claim.id = analysis.claim_id
    WHERE analysis.evidence_version = claim.evidence_version
      AND analysis.validation_status IN ('valid', 'fallback')
      AND validate_claim_analysis_output(analysis.output_payload)
      AND EXISTS (
        SELECT 1
        FROM claim_observations AS link
        JOIN observations AS observation ON observation.id = link.observation_id
        WHERE link.claim_id = claim.id
          AND observation.is_historical = false
      )
      AND 1 = (
        SELECT count(*)
        FROM organization_matches AS organization_match
        WHERE organization_match.claim_id = claim.id
          AND organization_match.review_status IN ('accepted', 'auto_accepted')
      )
      AND EXISTS (
        SELECT 1
        FROM notification_channel_configs AS channel_config
        JOIN organization_matches AS accepted_match
          ON accepted_match.claim_id = claim.id
         AND accepted_match.review_status IN ('accepted', 'auto_accepted')
        WHERE channel_config.enabled = true
          AND NOT EXISTS (
            SELECT 1
            FROM notification_outbox AS outbox
            WHERE outbox.claim_id = claim.id
              AND outbox.organization_id = accepted_match.organization_id
              AND outbox.channel = channel_config.channel
              AND outbox.notification_type = 'new_claim'
          )
      )
  ),
  selected_analyses AS (
    SELECT ranked.claim_id, ranked.analysis_id
    FROM ranked_analyses AS ranked
    WHERE ranked.analysis_rank = 1
    ORDER BY ranked.claim_id
    LIMIT requested_limit
  )
  SELECT
    selected.claim_id,
    selected.analysis_id,
    enqueued.notification_id,
    enqueued.channel,
    enqueued.created
  FROM selected_analyses AS selected
  CROSS JOIN LATERAL enqueue_claim_notifications(
    selected.claim_id,
    selected.analysis_id,
    'new_claim'
  ) AS enqueued;
END;
$$;

INSERT INTO schema_migrations (version)
VALUES ('020_cross_source_correlation')
ON CONFLICT (version) DO NOTHING;

COMMIT;
