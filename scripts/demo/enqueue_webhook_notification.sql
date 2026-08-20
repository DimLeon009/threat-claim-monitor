\set ON_ERROR_STOP on

BEGIN;

CREATE TEMP TABLE demo_channel_snapshot ON COMMIT DROP AS
SELECT channel, enabled
FROM notification_channel_configs
FOR UPDATE;

CREATE TEMP TABLE demo_enqueue_result (
  notification_id uuid,
  channel text,
  created boolean
) ON COMMIT DROP;

DO $$
DECLARE
  resolved_claim_id uuid;
  resolved_evidence_version integer;
  resolved_analysis_id uuid;
BEGIN
  SELECT claim.id, claim.evidence_version
  INTO resolved_claim_id, resolved_evidence_version
  FROM collection_runs AS run
  JOIN claims AS claim ON claim.id = (run.metadata->>'demo_claim_id')::uuid
  WHERE run.id = '7d000000-0000-4000-8000-000000000010'
    AND run.metadata @> '{"synthetic":true,"fixture":"m6-end-to-end-v1"}'::jsonb;

  IF resolved_claim_id IS NULL THEN
    RAISE EXCEPTION 'synthetic demo claim not found; run the seed first';
  END IF;

  SELECT analysis.id
  INTO resolved_analysis_id
  FROM analyses AS analysis
  WHERE analysis.claim_id = resolved_claim_id
    AND analysis.evidence_version = resolved_evidence_version
    AND analysis.validation_status IN ('valid', 'fallback')
  ORDER BY (analysis.validation_status = 'valid') DESC, analysis.created_at DESC
  LIMIT 1;

  IF resolved_analysis_id IS NULL THEN
    RAISE EXCEPTION 'eligible synthetic demo analysis not found';
  END IF;

  UPDATE notification_channel_configs
  SET enabled = channel = 'webhook',
      updated_at = clock_timestamp();

  INSERT INTO demo_enqueue_result
  SELECT *
  FROM enqueue_claim_notifications(
    resolved_claim_id,
    resolved_analysis_id,
    'new_claim'
  );

  UPDATE notification_channel_configs AS config
  SET enabled = snapshot.enabled,
      updated_at = clock_timestamp()
  FROM demo_channel_snapshot AS snapshot
  WHERE snapshot.channel = config.channel;
END;
$$;

DO $$
DECLARE
  resolved_claim_id uuid;
BEGIN
  SELECT (metadata->>'demo_claim_id')::uuid
  INTO resolved_claim_id
  FROM collection_runs
  WHERE id = '7d000000-0000-4000-8000-000000000010';

  IF (SELECT count(*) FROM demo_enqueue_result) <> 1
    OR EXISTS (
      SELECT 1 FROM demo_enqueue_result WHERE channel <> 'webhook'
    )
    OR EXISTS (
      SELECT 1
      FROM notification_outbox
      WHERE claim_id = resolved_claim_id
        AND channel <> 'webhook'
    )
  THEN
    RAISE EXCEPTION 'synthetic demo did not create exactly one isolated webhook job';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM notification_channel_configs AS config
    JOIN demo_channel_snapshot AS snapshot USING (channel)
    WHERE config.enabled IS DISTINCT FROM snapshot.enabled
  ) THEN
    RAISE EXCEPTION 'notification channel configuration was not restored';
  END IF;
END;
$$;

TABLE demo_enqueue_result;

COMMIT;

\echo 'Synthetic M6 webhook job enqueued; channel configuration restored.'
