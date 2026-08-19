BEGIN;

ALTER TABLE notification_outbox
  ADD COLUMN IF NOT EXISTS lease_token uuid,
  ADD COLUMN IF NOT EXISTS lease_expires_at timestamptz;

UPDATE notification_outbox
SET status = 'retry',
    available_at = now(),
    lease_token = null,
    lease_expires_at = null,
    last_error = 'notification lease reset during dispatcher upgrade',
    updated_at = now()
WHERE status = 'processing';

ALTER TABLE notification_outbox
  DROP CONSTRAINT IF EXISTS notification_outbox_processing_lease_check;

ALTER TABLE notification_outbox
  ADD CONSTRAINT notification_outbox_processing_lease_check
  CHECK (
    (status = 'processing' AND lease_token IS NOT NULL AND lease_expires_at IS NOT NULL)
    OR
    (status <> 'processing' AND lease_token IS NULL AND lease_expires_at IS NULL)
  );

CREATE INDEX IF NOT EXISTS notification_outbox_claim_idx
  ON notification_outbox (channel, status, available_at, lease_expires_at, created_at)
  WHERE status IN ('pending', 'retry', 'processing');

CREATE OR REPLACE FUNCTION claim_notification_jobs(
  requested_channel text,
  requested_limit integer DEFAULT 10,
  requested_lease_seconds integer DEFAULT 300
)
RETURNS TABLE (
  notification_id uuid,
  lease_token uuid,
  lease_expires_at timestamptz,
  channel text,
  notification_type text,
  payload jsonb,
  attempts integer
)
LANGUAGE plpgsql
AS $$
BEGIN
  IF requested_channel IS NULL
    OR requested_channel NOT IN ('webhook', 'email', 'teams')
  THEN
    RAISE EXCEPTION 'unsupported notification channel';
  END IF;

  IF requested_limit IS NULL OR requested_limit NOT BETWEEN 1 AND 100 THEN
    RAISE EXCEPTION 'notification claim limit must be between 1 and 100';
  END IF;

  IF requested_lease_seconds IS NULL
    OR requested_lease_seconds NOT BETWEEN 30 AND 900
  THEN
    RAISE EXCEPTION 'notification lease must be between 30 and 900 seconds';
  END IF;

  RETURN QUERY
  WITH claimable AS (
    SELECT outbox.id
    FROM notification_outbox AS outbox
    WHERE outbox.channel = requested_channel
      AND (
        (
          outbox.status IN ('pending', 'retry')
          AND outbox.available_at <= clock_timestamp()
        )
        OR
        (
          outbox.status = 'processing'
          AND outbox.lease_expires_at <= clock_timestamp()
        )
      )
    ORDER BY
      CASE WHEN outbox.status = 'processing' THEN 0 ELSE 1 END,
      outbox.available_at,
      outbox.created_at,
      outbox.id
    FOR UPDATE SKIP LOCKED
    LIMIT requested_limit
  ),
  claimed AS (
    UPDATE notification_outbox AS outbox
    SET status = 'processing',
        lease_token = gen_random_uuid(),
        lease_expires_at = clock_timestamp() + make_interval(secs => requested_lease_seconds),
        updated_at = clock_timestamp()
    FROM claimable
    WHERE outbox.id = claimable.id
    RETURNING outbox.*
  )
  SELECT
    claimed.id,
    claimed.lease_token,
    claimed.lease_expires_at,
    claimed.channel,
    claimed.notification_type,
    claimed.payload,
    claimed.attempts
  FROM claimed
  ORDER BY claimed.created_at, claimed.id;
END;
$$;

INSERT INTO schema_migrations (version)
VALUES ('014_notification_job_leases')
ON CONFLICT (version) DO NOTHING;

COMMIT;
