BEGIN;

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
            WHERE outbox.deduplication_key = format(
              'notification-v1:%s:%s:%s:new_claim:%s',
              claim.id,
              accepted_match.organization_id,
              channel_config.channel,
              claim.evidence_version
            )
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
VALUES ('017_notification_outbox_workflow')
ON CONFLICT (version) DO NOTHING;

COMMIT;
