\set ON_ERROR_STOP on

DO $$
DECLARE
  resolved_claim_id uuid;
  demo_job_count integer;
  unrelated_job_count integer;
BEGIN
  SELECT (metadata->>'demo_claim_id')::uuid
  INTO resolved_claim_id
  FROM collection_runs
  WHERE id = '7d000000-0000-4000-8000-000000000010'
    AND metadata @> '{"synthetic":true,"fixture":"m6-end-to-end-v1"}'::jsonb;

  IF resolved_claim_id IS NULL THEN
    RAISE EXCEPTION 'synthetic demo claim not found';
  END IF;

  SELECT count(*)
  INTO demo_job_count
  FROM notification_outbox
  WHERE claim_id = resolved_claim_id
    AND channel = 'webhook'
    AND (
      (status IN ('pending', 'retry') AND available_at <= clock_timestamp())
      OR (status = 'processing' AND lease_expires_at <= clock_timestamp())
    );

  SELECT count(*)
  INTO unrelated_job_count
  FROM notification_outbox
  WHERE claim_id <> resolved_claim_id
    AND channel = 'webhook'
    AND (
      (status IN ('pending', 'retry') AND available_at <= clock_timestamp())
      OR (status = 'processing' AND lease_expires_at <= clock_timestamp())
    );

  IF demo_job_count <> 1 THEN
    RAISE EXCEPTION 'expected exactly one dispatchable synthetic webhook job, found %', demo_job_count;
  END IF;
  IF unrelated_job_count <> 0 THEN
    RAISE EXCEPTION 'webhook dispatch blocked: % unrelated job(s) are also dispatchable', unrelated_job_count;
  END IF;
END;
$$;

SELECT
  outbox.id AS notification_id,
  outbox.status,
  outbox.attempts,
  outbox.payload->>'contract_version' AS contract_version,
  outbox.payload->'organization'->>'name' AS organization_name
FROM notification_outbox AS outbox
JOIN collection_runs AS run
  ON outbox.claim_id = (run.metadata->>'demo_claim_id')::uuid
WHERE run.id = '7d000000-0000-4000-8000-000000000010'
  AND outbox.channel = 'webhook';

\echo 'Synthetic M6 webhook dispatch preflight passed.'
