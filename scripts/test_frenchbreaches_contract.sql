\set ON_ERROR_STOP on

BEGIN;

UPDATE sources
SET enabled = true,
    metadata = metadata - 'baseline_completed_at'
WHERE slug = 'frenchbreaches';

CREATE TEMP TABLE frenchbreaches_first_run AS
SELECT *
FROM ingest_frenchbreaches_collection(
  '[
    {
      "title":"Synthetic French Organization",
      "guid":"https://frenchbreaches.com/incidents/tcm-synthetic-french-organization",
      "link":"https://frenchbreaches.com/incidents/tcm-synthetic-french-organization",
      "published_at":"2026-08-19T08:30:00.000Z"
    },
    {
      "title":"Synthetic French Services",
      "guid":"https://frenchbreaches.com/incidents/tcm-synthetic-french-services",
      "link":"https://frenchbreaches.com/incidents/tcm-synthetic-french-services",
      "published_at":"2026-08-19T09:30:00.000Z"
    },
    {
      "title":"*********",
      "guid":"https://frenchbreaches.com/incidents/tcm-synthetic-masked",
      "link":"https://frenchbreaches.com/incidents/tcm-synthetic-masked",
      "published_at":"2026-08-19T10:30:00.000Z"
    }
  ]'::jsonb
);

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM frenchbreaches_first_run
    WHERE fetched_count = 3
      AND inserted_count = 2
      AND is_baseline = true
  ) OR NOT EXISTS (
    SELECT 1
    FROM collection_runs AS run
    JOIN frenchbreaches_first_run AS fixture
      ON fixture.collection_run_id = run.id
    WHERE run.status = 'succeeded'
      AND run.metadata->>'rejected_unmatchable_count' = '1'
  ) THEN
    RAISE EXCEPTION 'FrenchBreaches baseline ingestion is invalid';
  END IF;
END;
$$;

SELECT *
FROM correlate_collection_run_exact(
  (SELECT collection_run_id FROM frenchbreaches_first_run)
);

DO $$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM observations AS observation
    JOIN frenchbreaches_first_run AS fixture
      ON fixture.collection_run_id = observation.collection_run_id
    WHERE observation.is_historical = false
      OR observation.threat_actor IS NOT NULL
      OR observation.normalized_threat_actor IS NOT NULL
      OR observation.victim_domain IS NOT NULL
      OR observation.description IS NOT NULL
      OR observation.raw_payload - ARRAY['guid', 'link', 'published_at', 'title'] <> '{}'::jsonb
      OR (
        SELECT count(*)
        FROM jsonb_object_keys(observation.raw_payload)
      ) <> 4
  ) THEN
    RAISE EXCEPTION 'FrenchBreaches persisted payload is not minimal';
  END IF;
END;
$$;

CREATE TEMP TABLE frenchbreaches_replay AS
SELECT *
FROM ingest_frenchbreaches_collection(
  '[
    {
      "title":"Synthetic French Organization",
      "guid":"https://frenchbreaches.com/incidents/tcm-synthetic-french-organization",
      "link":"https://frenchbreaches.com/incidents/tcm-synthetic-french-organization",
      "published_at":"2026-08-19T08:30:00.000Z"
    },
    {
      "title":"Synthetic French Services",
      "guid":"https://frenchbreaches.com/incidents/tcm-synthetic-french-services",
      "link":"https://frenchbreaches.com/incidents/tcm-synthetic-french-services",
      "published_at":"2026-08-19T09:30:00.000Z"
    },
    {
      "title":"*********",
      "guid":"https://frenchbreaches.com/incidents/tcm-synthetic-masked",
      "link":"https://frenchbreaches.com/incidents/tcm-synthetic-masked",
      "published_at":"2026-08-19T10:30:00.000Z"
    }
  ]'::jsonb
);

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM frenchbreaches_replay
    WHERE fetched_count = 3
      AND inserted_count = 0
      AND is_baseline = false
  ) THEN
    RAISE EXCEPTION 'FrenchBreaches replay is not idempotent';
  END IF;
END;
$$;

ROLLBACK;

\echo 'FrenchBreaches RSS runtime validation passed.'
