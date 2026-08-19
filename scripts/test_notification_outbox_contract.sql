\set ON_ERROR_STOP on

BEGIN;

UPDATE notification_channel_configs
SET enabled = channel IN ('webhook', 'teams'), updated_at = now();

INSERT INTO claims (
  id, canonical_key, victim_name, normalized_victim_name, threat_actor,
  normalized_threat_actor, first_seen_at, last_seen_at, evidence_version
)
VALUES (
  '74000000-0000-4000-8000-000000000001',
  'synthetic-notification-contract-claim',
  'Example Notification Victim', 'example notification victim',
  'Example Notification Actor', 'example notification actor',
  '2026-08-19T08:00:00Z', '2026-08-19T08:00:00Z', 1
);

INSERT INTO observations (
  id, source_id, source_key, discovered_at, published_at,
  victim_name, normalized_victim_name, threat_actor, normalized_threat_actor,
  description, payload_hash, raw_payload, is_historical
)
VALUES (
  '74000000-0000-4000-8000-000000000011',
  '10000000-0000-4000-8000-000000000001',
  'synthetic-notification-contract-observation',
  '2026-08-19T08:00:00Z', '2026-08-19T07:55:00Z',
  'Example Notification Victim', 'example notification victim',
  'Example Notification Actor', 'example notification actor',
  'Synthetic public notification evidence.', repeat('4', 64),
  '{"fixture":"notification-contract"}'::jsonb, false
);

INSERT INTO claim_observations (claim_id, observation_id)
VALUES (
  '74000000-0000-4000-8000-000000000001',
  '74000000-0000-4000-8000-000000000011'
);

INSERT INTO organization_matches (
  claim_id, organization_id, matching_method, confidence_score, review_status, evidence
)
VALUES (
  '74000000-0000-4000-8000-000000000001',
  '20000000-0000-4000-8000-000000000001',
  'name_exact', 95, 'auto_accepted',
  '{"rule_version":"notification-contract-test","auto_alert_eligible":true}'::jsonb
);

INSERT INTO analyses (
  id, claim_id, model_name, model_digest, prompt_version, input_hash,
  output_payload, validation_status, evidence_version, input_payload,
  inference_metadata, provider, deployment_name, provider_metadata
)
VALUES (
  '74000000-0000-4000-8000-000000000021',
  '74000000-0000-4000-8000-000000000001',
  'qwen3:8b-q4_K_M', repeat('1', 64), 'claim-analysis-v1', repeat('2', 64),
  jsonb_build_object(
    'language', 'fr',
    'summary_fr', 'Une source publique relaie une déclaration synthétique non vérifiée.',
    'observed_facts', jsonb_build_array(jsonb_build_object(
      'statement_fr', 'Une observation synthétique est disponible.',
      'evidence_ids', jsonb_build_array('evidence-1')
    )),
    'uncertainties', jsonb_build_array('La compromission n’est pas confirmée.'),
    'disclaimer', U&'D\00E9claration criminelle non v\00E9rifi\00E9e ; aucune compromission n\2019est confirm\00E9e.'
  ),
  'valid', 1,
  '{"observations":[{"evidence_id":"evidence-1"}]}'::jsonb,
  '{}'::jsonb, 'ollama', 'qwen3:8b-q4_K_M', '{}'::jsonb
);

CREATE TEMP TABLE first_enqueue AS
SELECT *
FROM enqueue_claim_notifications(
  '74000000-0000-4000-8000-000000000001',
  '74000000-0000-4000-8000-000000000021',
  'new_claim'
);

CREATE TEMP TABLE replay_enqueue AS
SELECT *
FROM enqueue_claim_notifications(
  '74000000-0000-4000-8000-000000000001',
  '74000000-0000-4000-8000-000000000021',
  'new_claim'
);

DO $$
BEGIN
  IF (SELECT count(*) FROM first_enqueue) <> 2
    OR EXISTS (SELECT 1 FROM first_enqueue WHERE created = false)
  THEN
    RAISE EXCEPTION 'first enqueue did not create one job per enabled channel';
  END IF;

  IF (SELECT count(*) FROM replay_enqueue) <> 2
    OR EXISTS (SELECT 1 FROM replay_enqueue WHERE created = true)
  THEN
    RAISE EXCEPTION 'notification enqueue replay was not idempotent';
  END IF;

  IF (SELECT count(*) FROM notification_outbox
      WHERE claim_id = '74000000-0000-4000-8000-000000000001') <> 2
    OR EXISTS (
      SELECT 1
      FROM notification_outbox
      WHERE claim_id = '74000000-0000-4000-8000-000000000001'
        AND channel NOT IN ('webhook', 'teams')
    )
  THEN
    RAISE EXCEPTION 'outbox jobs do not match enabled channels';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM notification_outbox
    WHERE claim_id = '74000000-0000-4000-8000-000000000001'
      AND (
        status <> 'pending'
        OR attempts <> 0
        OR NOT validate_notification_payload(payload)
        OR payload->>'contract_version' <> 'notification-v1'
        OR payload->'claim'->>'verification_status' <> 'claimed'
        OR payload->'match'->>'method' <> 'name_exact'
        OR (payload->'match'->>'confidence_score')::integer <> 95
        OR payload->'analysis'->>'provider' <> 'ollama'
        OR payload->'analysis'->>'summary_fr'
          <> 'Une source publique relaie une déclaration synthétique non vérifiée.'
        OR payload->>'disclaimer'
          <> U&'D\00E9claration criminelle non v\00E9rifi\00E9e ; aucune compromission n\2019est confirm\00E9e.'
        OR jsonb_array_length(payload->'sources') <> 1
        OR payload::text ~* 'https?://|api[_-]?key|authorization|bearer\s|secret|token'
      )
  ) THEN
    RAISE EXCEPTION 'stored notification payload violates the common contract';
  END IF;
END;
$$;

CREATE TEMP TABLE first_webhook_claim AS
SELECT * FROM claim_notification_jobs('webhook', 10, 300);

CREATE TEMP TABLE blocked_webhook_claim AS
SELECT * FROM claim_notification_jobs('webhook', 10, 300);

DO $$
BEGIN
  IF (SELECT count(*) FROM first_webhook_claim) <> 1
    OR EXISTS (
      SELECT 1
      FROM first_webhook_claim
      WHERE lease_token IS NULL
        OR lease_expires_at <= clock_timestamp()
        OR channel <> 'webhook'
        OR attempts <> 0
        OR NOT validate_notification_payload(payload)
    )
  THEN
    RAISE EXCEPTION 'eligible webhook job was not leased correctly';
  END IF;

  IF EXISTS (SELECT 1 FROM blocked_webhook_claim) THEN
    RAISE EXCEPTION 'active notification lease was claimed twice';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM notification_outbox AS outbox
    JOIN first_webhook_claim AS claimed ON claimed.notification_id = outbox.id
    WHERE outbox.status <> 'processing'
      OR outbox.lease_token IS DISTINCT FROM claimed.lease_token
  ) THEN
    RAISE EXCEPTION 'claimed notification state is inconsistent';
  END IF;
END;
$$;

UPDATE notification_outbox AS outbox
SET lease_expires_at = clock_timestamp() - interval '1 second'
FROM first_webhook_claim AS claimed
WHERE outbox.id = claimed.notification_id;

CREATE TEMP TABLE reclaimed_webhook_job AS
SELECT * FROM claim_notification_jobs('webhook', 10, 300);

DO $$
BEGIN
  IF (SELECT count(*) FROM reclaimed_webhook_job) <> 1
    OR EXISTS (
      SELECT 1
      FROM reclaimed_webhook_job AS reclaimed
      JOIN first_webhook_claim AS original
        ON original.notification_id = reclaimed.notification_id
      WHERE original.lease_token = reclaimed.lease_token
    )
  THEN
    RAISE EXCEPTION 'expired notification lease was not safely reclaimed';
  END IF;
END;
$$;

CREATE TEMP TABLE first_delivery_failure AS
SELECT result.*
FROM reclaimed_webhook_job AS claimed
CROSS JOIN LATERAL record_notification_delivery_result_envelope(
  jsonb_build_object(
    'notification_id', claimed.notification_id,
    'lease_token', claimed.lease_token,
    'succeeded', false,
    'response_status', 503,
    'response_excerpt', 'Authorization: Bearer secret-token',
    'error_code', 'http_5xx'
  )
) AS result;

DO $$
DECLARE
  stale_notification_id uuid;
  stale_lease_token uuid;
BEGIN
  IF (SELECT count(*) FROM first_delivery_failure) <> 1
    OR EXISTS (
      SELECT 1
      FROM first_delivery_failure
      WHERE result_status <> 'retry'
        OR attempt_count <> 1
        OR next_available_at < clock_timestamp() + interval '55 seconds'
        OR next_available_at > clock_timestamp() + interval '65 seconds'
        OR delivered_at IS NOT NULL
    )
  THEN
    RAISE EXCEPTION 'notification failure did not schedule the expected retry';
  END IF;

  SELECT notification_id, lease_token
  INTO stale_notification_id, stale_lease_token
  FROM reclaimed_webhook_job;

  BEGIN
    PERFORM * FROM record_notification_delivery_result(
      stale_notification_id, stale_lease_token, true, 204, 'accepted', null
    );
    RAISE EXCEPTION 'stale notification lease was accepted';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'notification lease is not active' THEN
      RAISE;
    END IF;
  END;
END;
$$;

DO $$
DECLARE
  webhook_notification_id uuid;
  current_lease_token uuid;
  delivery_result record;
  failure_number integer;
BEGIN
  SELECT notification_id
  INTO webhook_notification_id
  FROM reclaimed_webhook_job;

  FOR failure_number IN 2..5 LOOP
    UPDATE notification_outbox
    SET available_at = clock_timestamp() - interval '1 second'
    WHERE id = webhook_notification_id;

    SELECT claimed.lease_token
    INTO current_lease_token
    FROM claim_notification_jobs('webhook', 1, 300) AS claimed;

    IF current_lease_token IS NULL THEN
      RAISE EXCEPTION 'retry notification could not be leased';
    END IF;

    SELECT result.*
    INTO delivery_result
    FROM record_notification_delivery_result(
      webhook_notification_id,
      current_lease_token,
      false,
      503,
      E'upstream\nserver error',
      'http_5xx'
    ) AS result;

    IF failure_number < 5 AND delivery_result.result_status <> 'retry' THEN
      RAISE EXCEPTION 'notification entered dead-letter too early';
    END IF;
    IF failure_number = 5 AND delivery_result.result_status <> 'dead_letter' THEN
      RAISE EXCEPTION 'notification did not reach dead-letter after five failures';
    END IF;
  END LOOP;
END;
$$;

DO $$
DECLARE
  webhook_notification_id uuid;
  post_requeue_lease uuid;
  success_result record;
BEGIN
  SELECT notification_id
  INTO webhook_notification_id
  FROM reclaimed_webhook_job;

  IF NOT EXISTS (
    SELECT 1
    FROM notification_outbox
    WHERE id = webhook_notification_id
      AND status = 'dead_letter'
      AND attempts = 5
      AND lease_token IS NULL
      AND lease_expires_at IS NULL
      AND last_error = 'notification endpoint returned a server error'
  ) THEN
    RAISE EXCEPTION 'notification did not reach dead-letter after five failures';
  END IF;

  IF (SELECT count(*) FROM notification_attempts
      WHERE notification_id = webhook_notification_id) <> 5
    OR NOT EXISTS (
      SELECT 1
      FROM notification_attempts
      WHERE notification_id = webhook_notification_id
        AND response_excerpt = '[redacted unsafe response]'
    )
    OR EXISTS (
      SELECT 1
      FROM notification_attempts
      WHERE notification_id = webhook_notification_id
        AND (
          length(response_excerpt) > 500
          OR response_excerpt ~* 'authorization|bearer|secret|token'
          OR error_message <> 'notification endpoint returned a server error'
        )
    )
  THEN
    RAISE EXCEPTION 'notification attempt history was not sanitized';
  END IF;

  PERFORM requeue_dead_letter_notification(webhook_notification_id);

  IF NOT EXISTS (
    SELECT 1
    FROM notification_outbox
    WHERE id = webhook_notification_id
      AND status = 'retry'
      AND attempts = 0
      AND last_error IS NULL
  ) OR (SELECT count(*) FROM notification_attempts
        WHERE notification_id = webhook_notification_id) <> 5
  THEN
    RAISE EXCEPTION 'dead-letter notification was not safely requeued';
  END IF;

  SELECT claimed.lease_token
  INTO post_requeue_lease
  FROM claim_notification_jobs('webhook', 1, 300) AS claimed;

  SELECT result.*
  INTO success_result
  FROM record_notification_delivery_result(
    webhook_notification_id,
    post_requeue_lease,
    true,
    204,
    'accepted',
    null
  ) AS result;

  IF success_result.result_status <> 'sent'
    OR success_result.attempt_count <> 1
    OR success_result.delivered_at IS NULL
    OR NOT EXISTS (
      SELECT 1
      FROM notification_outbox
      WHERE id = webhook_notification_id
        AND status = 'sent'
        AND attempts = 1
        AND sent_at IS NOT NULL
        AND last_error IS NULL
        AND lease_token IS NULL
    )
    OR (SELECT count(*) FROM notification_attempts
        WHERE notification_id = webhook_notification_id) <> 6
  THEN
    RAISE EXCEPTION 'notification success was not finalized atomically';
  END IF;
END;
$$;

UPDATE notification_outbox
SET status = 'retry',
    available_at = clock_timestamp() + interval '1 hour',
    lease_token = null,
    lease_expires_at = null
WHERE claim_id = '74000000-0000-4000-8000-000000000001'
  AND channel = 'teams';

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM claim_notification_jobs('teams', 10, 300)) THEN
    RAISE EXCEPTION 'future retry job was claimed before available_at';
  END IF;

  BEGIN
    PERFORM * FROM claim_notification_jobs('unsupported', 10, 300);
    RAISE EXCEPTION 'unsupported notification channel was accepted';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'unsupported notification channel' THEN
      RAISE;
    END IF;
  END;

  BEGIN
    PERFORM * FROM claim_notification_jobs('webhook', 0, 300);
    RAISE EXCEPTION 'invalid notification claim limit was accepted';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'notification claim limit must be between 1 and 100' THEN
      RAISE;
    END IF;
  END;
END;
$$;

INSERT INTO claims (
  id, canonical_key, victim_name, normalized_victim_name,
  first_seen_at, last_seen_at, evidence_version
)
VALUES (
  '74000000-0000-4000-8000-000000000002',
  'synthetic-historical-notification-claim',
  'Example Historical Victim', 'example historical victim',
  '2026-08-19T07:00:00Z', '2026-08-19T07:00:00Z', 1
);

INSERT INTO observations (
  id, source_id, source_key, discovered_at,
  victim_name, normalized_victim_name, payload_hash, raw_payload, is_historical
)
VALUES (
  '74000000-0000-4000-8000-000000000012',
  '10000000-0000-4000-8000-000000000001',
  'synthetic-historical-notification-observation',
  '2026-08-19T07:00:00Z',
  'Example Historical Victim', 'example historical victim', repeat('5', 64),
  '{"fixture":"historical-notification"}'::jsonb, true
);

INSERT INTO claim_observations (claim_id, observation_id)
VALUES (
  '74000000-0000-4000-8000-000000000002',
  '74000000-0000-4000-8000-000000000012'
);

INSERT INTO organization_matches (
  claim_id, organization_id, matching_method, confidence_score, review_status, evidence
)
VALUES (
  '74000000-0000-4000-8000-000000000002',
  '20000000-0000-4000-8000-000000000001',
  'name_exact', 95, 'auto_accepted',
  '{"rule_version":"historical-notification-test","auto_alert_eligible":true}'::jsonb
);

INSERT INTO analyses (
  id, claim_id, model_name, model_digest, prompt_version, input_hash,
  output_payload, validation_status, evidence_version, input_payload,
  inference_metadata, provider, deployment_name, provider_metadata
)
SELECT
  '74000000-0000-4000-8000-000000000022',
  '74000000-0000-4000-8000-000000000002',
  model_name, model_digest, prompt_version, repeat('3', 64), output_payload,
  validation_status, 1, input_payload, inference_metadata,
  provider, deployment_name, provider_metadata
FROM analyses
WHERE id = '74000000-0000-4000-8000-000000000021';

DO $$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM enqueue_claim_notifications(
      '74000000-0000-4000-8000-000000000002',
      '74000000-0000-4000-8000-000000000022',
      'new_claim'
    )
  ) THEN
    RAISE EXCEPTION 'historical evidence created a notification job';
  END IF;
END;
$$;

INSERT INTO claims (
  id, canonical_key, victim_name, normalized_victim_name, threat_actor,
  normalized_threat_actor, first_seen_at, last_seen_at, evidence_version
)
VALUES (
  '74000000-0000-4000-8000-000000000003',
  'synthetic-notification-producer-claim',
  'Example Producer Victim', 'example producer victim',
  'Example Producer Actor', 'example producer actor',
  '2026-08-19T09:00:00Z', '2026-08-19T09:00:00Z', 1
);

INSERT INTO observations (
  id, source_id, source_key, discovered_at, published_at,
  victim_name, normalized_victim_name, threat_actor, normalized_threat_actor,
  description, payload_hash, raw_payload, is_historical
)
VALUES (
  '74000000-0000-4000-8000-000000000013',
  '10000000-0000-4000-8000-000000000001',
  'synthetic-notification-producer-observation',
  '2026-08-19T09:00:00Z', '2026-08-19T08:55:00Z',
  'Example Producer Victim', 'example producer victim',
  'Example Producer Actor', 'example producer actor',
  'Synthetic producer evidence.', repeat('6', 64),
  '{"fixture":"notification-producer"}'::jsonb, false
);

INSERT INTO claim_observations (claim_id, observation_id)
VALUES (
  '74000000-0000-4000-8000-000000000003',
  '74000000-0000-4000-8000-000000000013'
);

INSERT INTO organization_matches (
  claim_id, organization_id, matching_method, confidence_score, review_status, evidence
)
VALUES (
  '74000000-0000-4000-8000-000000000003',
  '20000000-0000-4000-8000-000000000001',
  'name_exact', 95, 'auto_accepted',
  '{"rule_version":"notification-producer-test","auto_alert_eligible":true}'::jsonb
);

INSERT INTO analyses (
  id, claim_id, model_name, model_digest, prompt_version, input_hash,
  output_payload, validation_status, evidence_version, input_payload,
  inference_metadata, provider, deployment_name, provider_metadata
)
SELECT
  '74000000-0000-4000-8000-000000000023',
  '74000000-0000-4000-8000-000000000003',
  model_name, model_digest, prompt_version, repeat('7', 64), output_payload,
  validation_status, 1, input_payload, inference_metadata,
  provider, deployment_name, provider_metadata
FROM analyses
WHERE id = '74000000-0000-4000-8000-000000000021';

CREATE TEMP TABLE producer_enqueue AS
SELECT * FROM enqueue_ready_claim_notifications(100);

CREATE TEMP TABLE producer_replay AS
SELECT * FROM enqueue_ready_claim_notifications(100);

DO $$
BEGIN
  IF (SELECT count(*) FROM producer_enqueue
      WHERE claim_id = '74000000-0000-4000-8000-000000000003') <> 2
    OR EXISTS (
      SELECT 1
      FROM producer_enqueue
      WHERE claim_id = '74000000-0000-4000-8000-000000000003'
        AND (
          analysis_id <> '74000000-0000-4000-8000-000000000023'
          OR created = false
          OR channel NOT IN ('webhook', 'teams')
        )
    )
  THEN
    RAISE EXCEPTION 'WF-50 producer did not create the expected channel jobs';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM producer_replay
    WHERE claim_id = '74000000-0000-4000-8000-000000000003'
  ) THEN
    RAISE EXCEPTION 'WF-50 producer replay returned a fully enqueued claim';
  END IF;
END;
$$;

UPDATE claims
SET evidence_version = 2,
    verification_status = 'multi_source_observed',
    updated_at = now()
WHERE id = '74000000-0000-4000-8000-000000000003';

INSERT INTO analyses (
  id, claim_id, model_name, model_digest, prompt_version, input_hash,
  output_payload, validation_status, evidence_version, input_payload,
  inference_metadata, provider, deployment_name, provider_metadata
)
SELECT
  '74000000-0000-4000-8000-000000000024',
  '74000000-0000-4000-8000-000000000003',
  model_name, model_digest, prompt_version, repeat('8', 64), output_payload,
  validation_status, 2, input_payload, inference_metadata,
  provider, deployment_name, provider_metadata
FROM analyses
WHERE id = '74000000-0000-4000-8000-000000000023';

CREATE TEMP TABLE producer_cross_source_replay AS
SELECT * FROM enqueue_ready_claim_notifications(100);

DO $$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM producer_cross_source_replay
    WHERE claim_id = '74000000-0000-4000-8000-000000000003'
  ) OR (
    SELECT count(*)
    FROM notification_outbox
    WHERE claim_id = '74000000-0000-4000-8000-000000000003'
      AND notification_type = 'new_claim'
  ) <> 2 THEN
    RAISE EXCEPTION 'cross-source evidence created a duplicate new-claim notification';
  END IF;
END;
$$;

DO $$
BEGIN
  BEGIN
    PERFORM * FROM record_notification_delivery_result_envelope('{}'::jsonb);
    RAISE EXCEPTION 'invalid delivery result envelope was accepted';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'invalid notification delivery result envelope' THEN
      RAISE;
    END IF;
  END;

  BEGIN
    INSERT INTO notification_outbox (
      claim_id, organization_id, channel, notification_type,
      evidence_version, deduplication_key, payload
    )
    VALUES (
      '74000000-0000-4000-8000-000000000001',
      '20000000-0000-4000-8000-000000000001',
      'email', 'new_claim', 1, 'synthetic-invalid-notification-payload', '{}'::jsonb
    );
    RAISE EXCEPTION 'invalid notification payload was accepted';
  EXCEPTION WHEN check_violation THEN
    NULL;
  END;
END;
$$;

DO $$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'notification_channel_configs'
      AND column_name ~* 'secret|token|key|password|credential|endpoint|url'
  ) THEN
    RAISE EXCEPTION 'notification channel configuration contains a secret-bearing column';
  END IF;
END;
$$;

ROLLBACK;

\echo 'Notification outbox contract validation passed.'
