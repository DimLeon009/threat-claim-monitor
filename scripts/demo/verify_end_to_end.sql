\set ON_ERROR_STOP on

DO $$
DECLARE
  resolved_claim_id uuid;
BEGIN
  SELECT (metadata->>'demo_claim_id')::uuid
  INTO resolved_claim_id
  FROM collection_runs
  WHERE id = '7d000000-0000-4000-8000-000000000010'
    AND metadata @> '{"synthetic":true,"fixture":"m6-end-to-end-v1"}'::jsonb;

  IF resolved_claim_id IS NULL THEN
    RAISE EXCEPTION 'synthetic demo collection run is missing';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM claim_observations AS link
    JOIN observations AS observation ON observation.id = link.observation_id
    WHERE link.claim_id = resolved_claim_id
      AND observation.id = '7d000000-0000-4000-8000-000000000011'
      AND observation.is_historical = false
  ) THEN
    RAISE EXCEPTION 'synthetic observation is not linked to the claim';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM organization_matches
    WHERE claim_id = resolved_claim_id
      AND organization_id = '7d000000-0000-4000-8000-000000000002'
      AND matching_method = 'domain_exact'
      AND confidence_score = 100
      AND review_status = 'auto_accepted'
  ) THEN
    RAISE EXCEPTION 'synthetic exact organization match is invalid';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM analyses
    WHERE claim_id = resolved_claim_id
      AND validation_status IN ('valid', 'fallback')
  ) THEN
    RAISE EXCEPTION 'synthetic analysis is missing';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM notification_outbox AS outbox
    WHERE outbox.claim_id = resolved_claim_id
      AND outbox.channel = 'webhook'
      AND outbox.status = 'sent'
      AND outbox.sent_at IS NOT NULL
      AND validate_notification_payload(outbox.payload)
      AND outbox.payload->'organization'->>'name' = 'TCM Synthetic Demo Organization'
      AND EXISTS (
        SELECT 1
        FROM notification_attempts AS attempt
        WHERE attempt.notification_id = outbox.id
          AND attempt.succeeded = true
      )
  ) THEN
    RAISE EXCEPTION 'synthetic webhook alert has not been delivered successfully';
  END IF;
END;
$$;

SELECT
  run.id AS collection_run_id,
  claim.id AS claim_id,
  claim.verification_status,
  match.matching_method,
  match.confidence_score,
  analysis.validation_status AS analysis_status,
  analysis.provider,
  outbox.id AS notification_id,
  outbox.status AS delivery_status,
  outbox.attempts
FROM collection_runs AS run
JOIN claims AS claim ON claim.id = (run.metadata->>'demo_claim_id')::uuid
JOIN organization_matches AS match
  ON match.claim_id = claim.id
 AND match.organization_id = '7d000000-0000-4000-8000-000000000002'
JOIN LATERAL (
  SELECT candidate.*
  FROM analyses AS candidate
  WHERE candidate.claim_id = claim.id
  ORDER BY (candidate.validation_status = 'valid') DESC, candidate.created_at DESC
  LIMIT 1
) AS analysis ON true
JOIN notification_outbox AS outbox
  ON outbox.claim_id = claim.id
 AND outbox.channel = 'webhook'
WHERE run.id = '7d000000-0000-4000-8000-000000000010';

\echo 'End-to-end synthetic M6 demonstration passed.'
