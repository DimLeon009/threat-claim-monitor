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
    'disclaimer', 'Déclaration criminelle non vérifiée ; aucune compromission n’est confirmée.'
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
          <> 'Déclaration criminelle non vérifiée ; aucune compromission n’est confirmée.'
        OR jsonb_array_length(payload->'sources') <> 1
        OR payload::text ~* 'https?://|api[_-]?key|authorization|bearer\s|secret|token'
      )
  ) THEN
    RAISE EXCEPTION 'stored notification payload violates the common contract';
  END IF;
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

DO $$
BEGIN
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
