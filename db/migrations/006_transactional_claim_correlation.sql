BEGIN;

CREATE OR REPLACE FUNCTION correlate_observation_exact(observation_record_id uuid)
RETURNS TABLE (
  claim_id uuid,
  claim_created boolean,
  observation_link_created boolean,
  evidence_version integer,
  persisted_match_count integer,
  auto_accepted_match_count integer
)
LANGUAGE plpgsql
AS $$
DECLARE
  observation_record observations%ROWTYPE;
  resolved_claim_id uuid;
  linked_claim_id uuid;
  candidate_claim_ids uuid[];
  candidate_claim_count integer;
  created_claim boolean := false;
  created_link boolean := false;
  resolved_evidence_version integer;
  match_count integer;
  accepted_match_count integer;
  normalized_victim text;
  normalized_actor text;
  normalized_candidate_domain text;
  observation_time timestamptz;
  generated_canonical_key text;
BEGIN
  SELECT *
  INTO observation_record
  FROM observations
  WHERE id = observation_record_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'observation not found';
  END IF;

  SELECT claim_observation.claim_id
  INTO linked_claim_id
  FROM claim_observations AS claim_observation
  WHERE claim_observation.observation_id = observation_record.id;

  IF linked_claim_id IS NOT NULL THEN
    SELECT claim.evidence_version
    INTO resolved_evidence_version
    FROM claims AS claim
    WHERE claim.id = linked_claim_id;

    SELECT count(*)::integer,
           count(*) FILTER (WHERE review_status = 'auto_accepted')::integer
    INTO match_count, accepted_match_count
    FROM organization_matches
    WHERE organization_matches.claim_id = linked_claim_id;

    RETURN QUERY
    SELECT
      linked_claim_id,
      false,
      false,
      resolved_evidence_version,
      match_count,
      accepted_match_count;
    RETURN;
  END IF;

  normalized_victim := normalize_match_text(observation_record.victim_name);
  normalized_actor := normalize_threat_actor(observation_record.threat_actor);
  normalized_candidate_domain := normalize_domain(observation_record.victim_domain);
  observation_time := coalesce(
    observation_record.published_at,
    observation_record.discovered_at,
    observation_record.fetched_at,
    observation_record.created_at
  );

  IF normalized_victim IS NULL THEN
    RAISE EXCEPTION 'observation victim name cannot be normalized';
  END IF;

  -- The V1 deployment has one correlation worker. A transaction-scoped global
  -- advisory lock favors correctness over throughput and prevents concurrent
  -- observations from creating overlapping claims under different source keys.
  PERFORM pg_advisory_xact_lock(
    hashtextextended('threat-claim-monitor:claim-correlation', 0)
  );

  SELECT array_agg(candidate.id ORDER BY candidate.last_seen_at DESC, candidate.id),
         count(*)::integer
  INTO candidate_claim_ids, candidate_claim_count
  FROM claims AS candidate
  WHERE normalize_threat_actor(candidate.threat_actor) IS NOT DISTINCT FROM normalized_actor
    AND (
      normalize_match_text(candidate.victim_name) = normalized_victim
      OR (
        normalized_candidate_domain IS NOT NULL
        AND normalize_domain(candidate.victim_domain) = normalized_candidate_domain
      )
    )
    AND observation_time >= candidate.first_seen_at - interval '45 days'
    AND observation_time <= candidate.last_seen_at + interval '45 days';

  IF candidate_claim_count > 1 THEN
    RAISE EXCEPTION 'ambiguous claim correlation for observation';
  ELSIF candidate_claim_count = 1 THEN
    resolved_claim_id := candidate_claim_ids[1];
  ELSE
    generated_canonical_key := encode(
      digest(
        coalesce(normalized_candidate_domain, normalized_victim)
          || E'\n'
          || coalesce(normalized_actor, '')
          || E'\n'
          || observation_time::date::text,
        'sha256'
      ),
      'hex'
    );

    INSERT INTO claims (
      canonical_key,
      victim_name,
      normalized_victim_name,
      victim_domain,
      threat_actor,
      normalized_threat_actor,
      claimed_at,
      first_seen_at,
      last_seen_at
    )
    VALUES (
      generated_canonical_key,
      observation_record.victim_name,
      normalized_victim,
      normalized_candidate_domain,
      observation_record.threat_actor,
      normalized_actor,
      observation_record.published_at,
      observation_time,
      observation_time
    )
    RETURNING id INTO resolved_claim_id;

    created_claim := true;
  END IF;

  INSERT INTO claim_observations (claim_id, observation_id)
  VALUES (resolved_claim_id, observation_record.id)
  ON CONFLICT (observation_id) DO NOTHING
  RETURNING true INTO created_link;

  IF NOT coalesce(created_link, false) THEN
    SELECT claim_observation.claim_id
    INTO linked_claim_id
    FROM claim_observations AS claim_observation
    WHERE claim_observation.observation_id = observation_record.id;

    IF linked_claim_id IS DISTINCT FROM resolved_claim_id THEN
      RAISE EXCEPTION 'observation already linked to a different claim';
    END IF;
  END IF;

  IF created_link AND NOT created_claim THEN
    UPDATE claims AS claim
    SET first_seen_at = least(claim.first_seen_at, observation_time),
        last_seen_at = greatest(claim.last_seen_at, observation_time),
        evidence_version = claim.evidence_version + 1,
        updated_at = now()
    WHERE claim.id = resolved_claim_id
    RETURNING claim.evidence_version INTO resolved_evidence_version;
  ELSE
    SELECT claims.evidence_version
    INTO resolved_evidence_version
    FROM claims
    WHERE claims.id = resolved_claim_id;
  END IF;

  INSERT INTO organization_matches (
    claim_id,
    organization_id,
    matching_method,
    confidence_score,
    review_status,
    evidence
  )
  SELECT
    resolved_claim_id,
    candidate.organization_id,
    candidate.matching_method,
    candidate.confidence_score,
    candidate.review_status,
    candidate.evidence || jsonb_build_object(
      'observation_id', observation_record.id,
      'claim_evidence_version', resolved_evidence_version
    )
  FROM find_exact_organization_matches(
    observation_record.victim_name,
    observation_record.victim_domain
  ) AS candidate
  ON CONFLICT ON CONSTRAINT organization_matches_claim_id_organization_id_key DO UPDATE
  SET matching_method = CASE
        WHEN organization_matches.review_status IN ('accepted', 'rejected')
          THEN organization_matches.matching_method
        WHEN EXCLUDED.confidence_score > organization_matches.confidence_score
          THEN EXCLUDED.matching_method
        ELSE organization_matches.matching_method
      END,
      confidence_score = CASE
        WHEN organization_matches.review_status IN ('accepted', 'rejected')
          THEN organization_matches.confidence_score
        ELSE greatest(organization_matches.confidence_score, EXCLUDED.confidence_score)
      END,
      review_status = CASE
        WHEN organization_matches.review_status IN ('accepted', 'rejected')
          THEN organization_matches.review_status
        ELSE EXCLUDED.review_status
      END,
      evidence = CASE
        WHEN organization_matches.review_status IN ('accepted', 'rejected')
          THEN organization_matches.evidence
        WHEN EXCLUDED.confidence_score >= organization_matches.confidence_score
          THEN EXCLUDED.evidence
        ELSE organization_matches.evidence || jsonb_build_object(
          'last_observation_id', observation_record.id,
          'claim_evidence_version', resolved_evidence_version
        )
      END;

  SELECT count(*)::integer
  INTO match_count
  FROM organization_matches
  WHERE organization_matches.claim_id = resolved_claim_id;

  IF match_count > 1 THEN
    UPDATE organization_matches
    SET review_status = 'pending',
        evidence = evidence || jsonb_build_object(
          'candidate_organization_count', match_count,
          'collision', true,
          'auto_alert_eligible', false
        )
    WHERE organization_matches.claim_id = resolved_claim_id
      AND organization_matches.review_status IN ('pending', 'auto_accepted');
  END IF;

  SELECT count(*) FILTER (WHERE review_status = 'auto_accepted')::integer
  INTO accepted_match_count
  FROM organization_matches
  WHERE organization_matches.claim_id = resolved_claim_id;

  RETURN QUERY
  SELECT
    resolved_claim_id,
    created_claim,
    coalesce(created_link, false),
    resolved_evidence_version,
    match_count,
    accepted_match_count;
END;
$$;

INSERT INTO schema_migrations (version)
VALUES ('006_transactional_claim_correlation')
ON CONFLICT (version) DO NOTHING;

COMMIT;
