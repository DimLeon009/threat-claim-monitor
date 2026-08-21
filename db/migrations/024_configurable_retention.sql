BEGIN;

CREATE TABLE IF NOT EXISTS retention_policy (
  id smallint PRIMARY KEY DEFAULT 1 CHECK (id = 1),
  enabled boolean NOT NULL DEFAULT false,
  collection_run_retention_days integer NOT NULL DEFAULT 90
    CHECK (collection_run_retention_days BETWEEN 7 AND 3650),
  max_collection_runs_per_job integer NOT NULL DEFAULT 1000
    CHECK (max_collection_runs_per_job BETWEEN 1 AND 10000),
  updated_at timestamptz NOT NULL DEFAULT now()
);

INSERT INTO retention_policy (id)
VALUES (1)
ON CONFLICT (id) DO NOTHING;

CREATE TABLE IF NOT EXISTS retention_runs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  started_at timestamptz NOT NULL,
  finished_at timestamptz NOT NULL,
  cutoff_at timestamptz NOT NULL,
  status text NOT NULL CHECK (status = 'succeeded'),
  deleted_collection_run_count integer NOT NULL CHECK (deleted_collection_run_count >= 0),
  policy_snapshot jsonb NOT NULL CHECK (jsonb_typeof(policy_snapshot) = 'object')
);

CREATE INDEX IF NOT EXISTS retention_runs_finished_at_idx
  ON retention_runs (finished_at DESC);

CREATE OR REPLACE FUNCTION set_retention_policy(
  requested_enabled boolean,
  requested_collection_run_retention_days integer,
  requested_max_collection_runs_per_job integer
)
RETURNS TABLE (
  enabled boolean,
  collection_run_retention_days integer,
  max_collection_runs_per_job integer,
  updated_at timestamptz
)
LANGUAGE plpgsql
AS $$
BEGIN
  IF requested_enabled IS NULL THEN
    RAISE EXCEPTION 'retention enabled state is required';
  END IF;
  IF requested_collection_run_retention_days NOT BETWEEN 7 AND 3650 THEN
    RAISE EXCEPTION 'collection-run retention days must be between 7 and 3650';
  END IF;
  IF requested_max_collection_runs_per_job NOT BETWEEN 1 AND 10000 THEN
    RAISE EXCEPTION 'retention job row limit must be between 1 and 10000';
  END IF;

  RETURN QUERY
  UPDATE retention_policy AS policy
  SET enabled = requested_enabled,
      collection_run_retention_days = requested_collection_run_retention_days,
      max_collection_runs_per_job = requested_max_collection_runs_per_job,
      updated_at = clock_timestamp()
  WHERE policy.id = 1
  RETURNING
    policy.enabled,
    policy.collection_run_retention_days,
    policy.max_collection_runs_per_job,
    policy.updated_at;
END;
$$;

CREATE OR REPLACE FUNCTION retention_collection_run_candidates(
  requested_cutoff_at timestamptz
)
RETURNS TABLE (collection_run_id uuid)
LANGUAGE sql
STABLE
STRICT
AS $$
  SELECT run.id
  FROM collection_runs AS run
  WHERE run.finished_at < requested_cutoff_at
    AND run.status IN ('succeeded', 'partial', 'failed')
    AND NOT EXISTS (
      SELECT 1
      FROM observations AS observation
      WHERE observation.collection_run_id = run.id
    )
    AND run.id IS DISTINCT FROM (
      SELECT latest.id
      FROM collection_runs AS latest
      WHERE latest.source_id = run.source_id
      ORDER BY latest.started_at DESC, latest.id DESC
      LIMIT 1
    )
    AND run.id IS DISTINCT FROM (
      SELECT latest_success.id
      FROM collection_runs AS latest_success
      WHERE latest_success.source_id = run.source_id
        AND latest_success.status = 'succeeded'
      ORDER BY latest_success.finished_at DESC NULLS LAST, latest_success.id DESC
      LIMIT 1
    )
    AND run.id IS DISTINCT FROM (
      SELECT latest_failure.id
      FROM collection_runs AS latest_failure
      WHERE latest_failure.source_id = run.source_id
        AND latest_failure.status IN ('partial', 'failed')
      ORDER BY latest_failure.finished_at DESC NULLS LAST, latest_failure.id DESC
      LIMIT 1
    )
  ORDER BY run.finished_at, run.id;
$$;

CREATE OR REPLACE FUNCTION preview_retention_job()
RETURNS TABLE (
  enabled boolean,
  cutoff_at timestamptz,
  eligible_collection_run_count bigint,
  max_collection_runs_per_job integer
)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
  policy_record retention_policy%ROWTYPE;
BEGIN
  SELECT *
  INTO STRICT policy_record
  FROM retention_policy
  WHERE id = 1;

  enabled := policy_record.enabled;
  cutoff_at := statement_timestamp()
    - make_interval(days => policy_record.collection_run_retention_days);
  SELECT count(*)
  INTO eligible_collection_run_count
  FROM retention_collection_run_candidates(cutoff_at);
  max_collection_runs_per_job := policy_record.max_collection_runs_per_job;
  RETURN NEXT;
END;
$$;

CREATE OR REPLACE FUNCTION run_retention_job()
RETURNS TABLE (
  retention_run_id uuid,
  result_status text,
  cutoff_at timestamptz,
  deleted_collection_run_count integer
)
LANGUAGE plpgsql
AS $$
DECLARE
  policy_record retention_policy%ROWTYPE;
  started timestamp with time zone := clock_timestamp();
  resolved_cutoff timestamp with time zone;
  resolved_deleted_count integer := 0;
  resolved_run_id uuid;
BEGIN
  SELECT *
  INTO STRICT policy_record
  FROM retention_policy
  WHERE id = 1;

  resolved_cutoff := started
    - make_interval(days => policy_record.collection_run_retention_days);

  IF NOT policy_record.enabled THEN
    retention_run_id := null;
    result_status := 'disabled';
    cutoff_at := resolved_cutoff;
    deleted_collection_run_count := 0;
    RETURN NEXT;
    RETURN;
  END IF;

  IF NOT pg_try_advisory_xact_lock(hashtextextended('tcm-retention-job', 0)) THEN
    retention_run_id := null;
    result_status := 'already_running';
    cutoff_at := resolved_cutoff;
    deleted_collection_run_count := 0;
    RETURN NEXT;
    RETURN;
  END IF;

  WITH selected AS (
    SELECT run.id
    FROM collection_runs AS run
    JOIN retention_collection_run_candidates(resolved_cutoff) AS candidate
      ON candidate.collection_run_id = run.id
    ORDER BY run.finished_at, run.id
    LIMIT policy_record.max_collection_runs_per_job
    FOR UPDATE OF run SKIP LOCKED
  ), deleted AS (
    DELETE FROM collection_runs AS run
    USING selected
    WHERE run.id = selected.id
      AND NOT EXISTS (
        SELECT 1
        FROM observations AS observation
        WHERE observation.collection_run_id = run.id
      )
    RETURNING run.id
  )
  SELECT count(*)::integer
  INTO resolved_deleted_count
  FROM deleted;

  INSERT INTO retention_runs (
    started_at,
    finished_at,
    cutoff_at,
    status,
    deleted_collection_run_count,
    policy_snapshot
  )
  VALUES (
    started,
    clock_timestamp(),
    resolved_cutoff,
    'succeeded',
    resolved_deleted_count,
    jsonb_build_object(
      'collection_run_retention_days', policy_record.collection_run_retention_days,
      'max_collection_runs_per_job', policy_record.max_collection_runs_per_job
    )
  )
  RETURNING id INTO resolved_run_id;

  retention_run_id := resolved_run_id;
  result_status := 'succeeded';
  cutoff_at := resolved_cutoff;
  deleted_collection_run_count := resolved_deleted_count;
  RETURN NEXT;
END;
$$;

INSERT INTO schema_migrations (version)
VALUES ('024_configurable_retention')
ON CONFLICT (version) DO NOTHING;

COMMIT;
