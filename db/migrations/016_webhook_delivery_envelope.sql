BEGIN;

CREATE OR REPLACE FUNCTION record_notification_delivery_result_envelope(candidate jsonb)
RETURNS TABLE (
  notification_id uuid,
  result_status text,
  attempt_count integer,
  next_available_at timestamptz,
  delivered_at timestamptz
)
LANGUAGE plpgsql
AS $$
BEGIN
  IF candidate IS NULL
    OR jsonb_typeof(candidate) <> 'object'
    OR NOT (candidate ?& ARRAY[
      'notification_id', 'lease_token', 'succeeded',
      'response_status', 'response_excerpt', 'error_code'
    ])
    OR (SELECT count(*) FROM jsonb_object_keys(candidate)) <> 6
    OR candidate->>'notification_id'
      !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
    OR candidate->>'lease_token'
      !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
    OR jsonb_typeof(candidate->'succeeded') <> 'boolean'
    OR jsonb_typeof(candidate->'response_status') NOT IN ('number', 'null')
    OR jsonb_typeof(candidate->'response_excerpt') NOT IN ('string', 'null')
    OR jsonb_typeof(candidate->'error_code') NOT IN ('string', 'null')
  THEN
    RAISE EXCEPTION 'invalid notification delivery result envelope';
  END IF;

  RETURN QUERY
  SELECT result.*
  FROM record_notification_delivery_result(
    (candidate->>'notification_id')::uuid,
    (candidate->>'lease_token')::uuid,
    (candidate->>'succeeded')::boolean,
    CASE
      WHEN candidate->'response_status' = 'null'::jsonb THEN null
      ELSE (candidate->>'response_status')::integer
    END,
    candidate->>'response_excerpt',
    candidate->>'error_code'
  ) AS result;
END;
$$;

INSERT INTO schema_migrations (version)
VALUES ('016_webhook_delivery_envelope')
ON CONFLICT (version) DO NOTHING;

COMMIT;
