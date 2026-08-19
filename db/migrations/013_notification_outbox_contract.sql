BEGIN;

CREATE TABLE IF NOT EXISTS notification_channel_configs (
  channel text PRIMARY KEY CHECK (channel IN ('webhook', 'email', 'teams')),
  enabled boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

INSERT INTO notification_channel_configs (channel, enabled)
VALUES
  ('webhook', false),
  ('email', false),
  ('teams', false)
ON CONFLICT (channel) DO NOTHING;

CREATE OR REPLACE FUNCTION validate_notification_payload(candidate jsonb)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
STRICT
AS $$
  SELECT jsonb_typeof(candidate) = 'object'
    AND candidate ?& ARRAY[
      'contract_version', 'alert_id', 'notification_type', 'created_at',
      'organization', 'claim', 'match', 'analysis', 'sources', 'disclaimer'
    ]
    AND (SELECT count(*) FROM jsonb_object_keys(candidate)) = 10
    AND candidate->>'contract_version' = 'notification-v1'
    AND candidate->>'alert_id'
      ~ '^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
    AND candidate->>'notification_type' IN ('new_claim', 'status_change', 'correction')
    AND jsonb_typeof(candidate->'created_at') = 'string'
    AND jsonb_typeof(candidate->'organization') = 'object'
    AND candidate->'organization' ?& ARRAY['id', 'name']
    AND (SELECT count(*) FROM jsonb_object_keys(candidate->'organization')) = 2
    AND jsonb_typeof(candidate->'organization'->'id') = 'string'
    AND jsonb_typeof(candidate->'organization'->'name') = 'string'
    AND jsonb_typeof(candidate->'claim') = 'object'
    AND candidate->'claim' ?& ARRAY[
      'id', 'evidence_version', 'victim_name', 'threat_actor', 'claimed_at',
      'first_seen_at', 'last_seen_at', 'verification_status'
    ]
    AND (SELECT count(*) FROM jsonb_object_keys(candidate->'claim')) = 8
    AND jsonb_typeof(candidate->'claim'->'id') = 'string'
    AND jsonb_typeof(candidate->'claim'->'evidence_version') = 'number'
    AND jsonb_typeof(candidate->'claim'->'victim_name') = 'string'
    AND jsonb_typeof(candidate->'claim'->'threat_actor') IN ('string', 'null')
    AND jsonb_typeof(candidate->'claim'->'claimed_at') IN ('string', 'null')
    AND jsonb_typeof(candidate->'claim'->'first_seen_at') = 'string'
    AND jsonb_typeof(candidate->'claim'->'last_seen_at') = 'string'
    AND candidate->'claim'->>'verification_status' IN (
      'claimed', 'multi_source_observed', 'officially_confirmed', 'disputed', 'refuted'
    )
    AND jsonb_typeof(candidate->'match') = 'object'
    AND candidate->'match' ?& ARRAY[
      'method', 'confidence_score', 'review_status'
    ]
    AND (SELECT count(*) FROM jsonb_object_keys(candidate->'match')) = 3
    AND jsonb_typeof(candidate->'match'->'method') = 'string'
    AND jsonb_typeof(candidate->'match'->'confidence_score') = 'number'
    AND candidate->'match'->>'review_status' IN ('accepted', 'auto_accepted')
    AND jsonb_typeof(candidate->'analysis') = 'object'
    AND candidate->'analysis' ?& ARRAY[
      'id', 'provider', 'deployment_name', 'model_name', 'validation_status',
      'summary_fr', 'observed_facts', 'uncertainties'
    ]
    AND (SELECT count(*) FROM jsonb_object_keys(candidate->'analysis')) = 8
    AND jsonb_typeof(candidate->'analysis'->'id') = 'string'
    AND candidate->'analysis'->>'provider' IN ('ollama', 'microsoft_foundry')
    AND jsonb_typeof(candidate->'analysis'->'deployment_name') = 'string'
    AND jsonb_typeof(candidate->'analysis'->'model_name') = 'string'
    AND candidate->'analysis'->>'validation_status' IN ('valid', 'fallback')
    AND jsonb_typeof(candidate->'analysis'->'summary_fr') = 'string'
    AND jsonb_typeof(candidate->'analysis'->'observed_facts') = 'array'
    AND jsonb_typeof(candidate->'analysis'->'uncertainties') = 'array'
    AND jsonb_typeof(candidate->'sources') = 'array'
    AND jsonb_array_length(candidate->'sources') BETWEEN 1 AND 10
    AND NOT EXISTS (
      SELECT 1
      FROM jsonb_array_elements(candidate->'sources') AS source_item
      WHERE jsonb_typeof(source_item) <> 'object'
        OR NOT (source_item ?& ARRAY['name', 'discovered_at', 'published_at'])
        OR (SELECT count(*) FROM jsonb_object_keys(source_item)) <> 3
        OR jsonb_typeof(source_item->'name') <> 'string'
        OR jsonb_typeof(source_item->'discovered_at') NOT IN ('string', 'null')
        OR jsonb_typeof(source_item->'published_at') NOT IN ('string', 'null')
    )
    AND candidate->>'disclaimer'
      = 'Déclaration criminelle non vérifiée ; aucune compromission n’est confirmée.'
    AND candidate::text !~* 'https?://|api[_-]?key|authorization|bearer\s|secret|token';
$$;

ALTER TABLE notification_outbox
  DROP CONSTRAINT IF EXISTS notification_outbox_payload_contract_check;

ALTER TABLE notification_outbox
  ADD CONSTRAINT notification_outbox_payload_contract_check
  CHECK (validate_notification_payload(payload));

CREATE OR REPLACE FUNCTION enqueue_claim_notifications(
  requested_claim_id uuid,
  requested_analysis_id uuid,
  requested_notification_type text DEFAULT 'new_claim'
)
RETURNS TABLE (
  notification_id uuid,
  channel text,
  created boolean
)
LANGUAGE plpgsql
AS $$
DECLARE
  selected_claim claims%ROWTYPE;
  selected_analysis analyses%ROWTYPE;
  selected_match record;
  accepted_match_count integer;
  selected_channel record;
  generated_notification_id uuid;
  resolved_notification_id uuid;
  resolved_deduplication_key text;
  resolved_payload jsonb;
  was_created boolean;
BEGIN
  IF requested_notification_type IS NULL
    OR requested_notification_type NOT IN ('new_claim', 'status_change', 'correction')
  THEN
    RAISE EXCEPTION 'unsupported notification type';
  END IF;

  SELECT claim.*
  INTO selected_claim
  FROM claims AS claim
  WHERE claim.id = requested_claim_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'claim not found';
  END IF;

  SELECT analysis.*
  INTO selected_analysis
  FROM analyses AS analysis
  WHERE analysis.id = requested_analysis_id
    AND analysis.claim_id = selected_claim.id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'analysis not found for claim';
  END IF;

  IF selected_analysis.evidence_version IS DISTINCT FROM selected_claim.evidence_version THEN
    RAISE EXCEPTION 'analysis does not cover current evidence version';
  END IF;

  IF selected_analysis.validation_status NOT IN ('valid', 'fallback')
    OR NOT validate_claim_analysis_output(selected_analysis.output_payload)
  THEN
    RAISE EXCEPTION 'analysis is not eligible for notification';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM claim_observations AS link
    JOIN observations AS observation ON observation.id = link.observation_id
    WHERE link.claim_id = selected_claim.id
      AND observation.is_historical = false
  ) THEN
    RETURN;
  END IF;

  SELECT count(*)
  INTO accepted_match_count
  FROM organization_matches AS organization_match
  WHERE organization_match.claim_id = selected_claim.id
    AND organization_match.review_status IN ('accepted', 'auto_accepted');

  IF accepted_match_count = 0 THEN
    RETURN;
  END IF;
  IF accepted_match_count > 1 THEN
    RAISE EXCEPTION 'claim has multiple accepted organization matches';
  END IF;

  SELECT
    organization_match.organization_id,
    organization.name AS organization_name,
    organization_match.matching_method,
    organization_match.confidence_score,
    organization_match.review_status
  INTO selected_match
  FROM organization_matches AS organization_match
  JOIN organizations AS organization ON organization.id = organization_match.organization_id
  WHERE organization_match.claim_id = selected_claim.id
    AND organization_match.review_status IN ('accepted', 'auto_accepted');

  FOR selected_channel IN
    SELECT config.channel AS selected_channel_name
    FROM notification_channel_configs AS config
    WHERE config.enabled = true
    ORDER BY config.channel
  LOOP
    generated_notification_id := gen_random_uuid();
    resolved_deduplication_key := format(
      'notification-v1:%s:%s:%s:%s:%s',
      selected_claim.id,
      selected_match.organization_id,
      selected_channel.selected_channel_name,
      requested_notification_type,
      selected_claim.evidence_version
    );

    resolved_payload := jsonb_build_object(
      'contract_version', 'notification-v1',
      'alert_id', generated_notification_id,
      'notification_type', requested_notification_type,
      'created_at', now(),
      'organization', jsonb_build_object(
        'id', selected_match.organization_id,
        'name', selected_match.organization_name
      ),
      'claim', jsonb_build_object(
        'id', selected_claim.id,
        'evidence_version', selected_claim.evidence_version,
        'victim_name', selected_claim.victim_name,
        'threat_actor', selected_claim.threat_actor,
        'claimed_at', selected_claim.claimed_at,
        'first_seen_at', selected_claim.first_seen_at,
        'last_seen_at', selected_claim.last_seen_at,
        'verification_status', selected_claim.verification_status
      ),
      'match', jsonb_build_object(
        'method', selected_match.matching_method,
        'confidence_score', selected_match.confidence_score,
        'review_status', selected_match.review_status
      ),
      'analysis', jsonb_build_object(
        'id', selected_analysis.id,
        'provider', selected_analysis.provider,
        'deployment_name', selected_analysis.deployment_name,
        'model_name', selected_analysis.model_name,
        'validation_status', selected_analysis.validation_status,
        'summary_fr', selected_analysis.output_payload->>'summary_fr',
        'observed_facts', selected_analysis.output_payload->'observed_facts',
        'uncertainties', selected_analysis.output_payload->'uncertainties'
      ),
      'sources', (
        SELECT jsonb_agg(
          jsonb_build_object(
            'name', ranked_source.source_name,
            'discovered_at', ranked_source.discovered_at,
            'published_at', ranked_source.published_at
          )
          ORDER BY ranked_source.discovered_at DESC NULLS LAST, ranked_source.source_name
        )
        FROM (
          SELECT source.name AS source_name, observation.discovered_at, observation.published_at
          FROM claim_observations AS link
          JOIN observations AS observation ON observation.id = link.observation_id
          JOIN sources AS source ON source.id = observation.source_id
          WHERE link.claim_id = selected_claim.id
            AND observation.is_historical = false
          ORDER BY observation.discovered_at DESC NULLS LAST, observation.id
          LIMIT 10
        ) AS ranked_source
      ),
      'disclaimer', selected_analysis.output_payload->>'disclaimer'
    );

    resolved_notification_id := null;
    INSERT INTO notification_outbox (
      id, claim_id, organization_id, channel, notification_type,
      evidence_version, deduplication_key, payload
    )
    VALUES (
      generated_notification_id,
      selected_claim.id,
      selected_match.organization_id,
      selected_channel.selected_channel_name,
      requested_notification_type,
      selected_claim.evidence_version,
      resolved_deduplication_key,
      resolved_payload
    )
    ON CONFLICT (deduplication_key) DO NOTHING
    RETURNING id INTO resolved_notification_id;

    was_created := resolved_notification_id IS NOT NULL;
    IF NOT was_created THEN
      SELECT outbox.id
      INTO resolved_notification_id
      FROM notification_outbox AS outbox
      WHERE outbox.deduplication_key = resolved_deduplication_key;
    END IF;

    notification_id := resolved_notification_id;
    channel := selected_channel.selected_channel_name;
    created := was_created;
    RETURN NEXT;
  END LOOP;
END;
$$;

INSERT INTO schema_migrations (version)
VALUES ('013_notification_outbox_contract')
ON CONFLICT (version) DO NOTHING;

COMMIT;
