BEGIN;

CREATE OR REPLACE FUNCTION sanitize_notification_response_excerpt(candidate text)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE
    WHEN candidate IS NULL OR btrim(candidate) = '' THEN null
    WHEN candidate ~* 'https?://|api[_-]?key|authorization|bearer\s|secret|token|password|credential'
      THEN '[redacted unsafe response]'
    ELSE left(regexp_replace(candidate, '[[:cntrl:]]+', ' ', 'g'), 500)
  END;
$$;

CREATE OR REPLACE FUNCTION notification_delivery_error_message(error_code text)
RETURNS text
LANGUAGE sql
IMMUTABLE
STRICT
AS $$
  SELECT CASE error_code
    WHEN 'timeout' THEN 'notification delivery timed out'
    WHEN 'connection_failed' THEN 'notification endpoint connection failed'
    WHEN 'http_4xx' THEN 'notification endpoint rejected the request'
    WHEN 'http_5xx' THEN 'notification endpoint returned a server error'
    WHEN 'rate_limited' THEN 'notification endpoint rate limited the request'
    WHEN 'invalid_response' THEN 'notification endpoint returned an invalid response'
    WHEN 'credential_unavailable' THEN 'notification credential is unavailable'
    WHEN 'delivery_rejected' THEN 'notification delivery was rejected'
    WHEN 'workflow_error' THEN 'notification delivery workflow failed'
    ELSE null
  END;
$$;

CREATE OR REPLACE FUNCTION record_notification_delivery_result(
  requested_notification_id uuid,
  requested_lease_token uuid,
  requested_succeeded boolean,
  requested_response_status integer DEFAULT null,
  requested_response_excerpt text DEFAULT null,
  requested_error_code text DEFAULT null
)
RETURNS TABLE (
  notification_id uuid,
  result_status text,
  attempt_count integer,
  next_available_at timestamptz,
  delivered_at timestamptz
)
LANGUAGE plpgsql
AS $$
DECLARE
  selected_job notification_outbox%ROWTYPE;
  sanitized_excerpt text;
  sanitized_error text;
  resolved_attempt_count integer;
  resolved_status text;
  resolved_available_at timestamptz;
  resolved_sent_at timestamptz;
  retry_delay_seconds integer;
  max_attempts constant integer := 5;
BEGIN
  IF requested_notification_id IS NULL OR requested_lease_token IS NULL THEN
    RAISE EXCEPTION 'notification id and lease token are required';
  END IF;

  IF requested_succeeded IS NULL THEN
    RAISE EXCEPTION 'notification delivery result is required';
  END IF;

  IF requested_response_status IS NOT NULL
    AND requested_response_status NOT BETWEEN 100 AND 599
  THEN
    RAISE EXCEPTION 'notification response status must be between 100 and 599';
  END IF;

  IF requested_succeeded AND requested_error_code IS NOT NULL THEN
    RAISE EXCEPTION 'successful notification cannot include an error code';
  END IF;

  sanitized_error := notification_delivery_error_message(requested_error_code);
  IF NOT requested_succeeded AND sanitized_error IS NULL THEN
    RAISE EXCEPTION 'unsupported notification delivery error code';
  END IF;

  SELECT outbox.*
  INTO selected_job
  FROM notification_outbox AS outbox
  WHERE outbox.id = requested_notification_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'notification job not found';
  END IF;

  IF selected_job.status <> 'processing'
    OR selected_job.lease_token IS DISTINCT FROM requested_lease_token
  THEN
    RAISE EXCEPTION 'notification lease is not active';
  END IF;

  IF selected_job.lease_expires_at <= clock_timestamp() THEN
    RAISE EXCEPTION 'notification lease expired';
  END IF;

  sanitized_excerpt := sanitize_notification_response_excerpt(requested_response_excerpt);
  resolved_attempt_count := selected_job.attempts + 1;

  INSERT INTO notification_attempts (
    notification_id, succeeded, response_status, response_excerpt, error_message
  )
  VALUES (
    selected_job.id,
    requested_succeeded,
    requested_response_status,
    sanitized_excerpt,
    sanitized_error
  );

  IF requested_succeeded THEN
    resolved_status := 'sent';
    resolved_available_at := selected_job.available_at;
    resolved_sent_at := clock_timestamp();
  ELSIF resolved_attempt_count >= max_attempts THEN
    resolved_status := 'dead_letter';
    resolved_available_at := selected_job.available_at;
    resolved_sent_at := null;
  ELSE
    resolved_status := 'retry';
    retry_delay_seconds := least(
      3600,
      (60 * power(2, resolved_attempt_count - 1))::integer
    );
    resolved_available_at := clock_timestamp() + make_interval(secs => retry_delay_seconds);
    resolved_sent_at := null;
  END IF;

  UPDATE notification_outbox AS outbox
  SET status = resolved_status,
      attempts = resolved_attempt_count,
      available_at = resolved_available_at,
      sent_at = resolved_sent_at,
      last_error = sanitized_error,
      lease_token = null,
      lease_expires_at = null,
      updated_at = clock_timestamp()
  WHERE outbox.id = selected_job.id;

  notification_id := selected_job.id;
  result_status := resolved_status;
  attempt_count := resolved_attempt_count;
  next_available_at := resolved_available_at;
  delivered_at := resolved_sent_at;
  RETURN NEXT;
END;
$$;

CREATE OR REPLACE FUNCTION requeue_dead_letter_notification(
  requested_notification_id uuid
)
RETURNS boolean
LANGUAGE plpgsql
AS $$
BEGIN
  UPDATE notification_outbox AS outbox
  SET status = 'retry',
      attempts = 0,
      available_at = clock_timestamp(),
      sent_at = null,
      last_error = null,
      lease_token = null,
      lease_expires_at = null,
      updated_at = clock_timestamp()
  WHERE outbox.id = requested_notification_id
    AND outbox.status = 'dead_letter';

  IF NOT FOUND THEN
    RAISE EXCEPTION 'dead-letter notification job not found';
  END IF;

  RETURN true;
END;
$$;

INSERT INTO schema_migrations (version)
VALUES ('015_notification_delivery_results')
ON CONFLICT (version) DO NOTHING;

COMMIT;
