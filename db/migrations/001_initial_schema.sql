BEGIN;

CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE TABLE IF NOT EXISTS schema_migrations (
  version text PRIMARY KEY,
  applied_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS sources (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  slug text NOT NULL UNIQUE,
  name text NOT NULL,
  source_kind text NOT NULL CHECK (source_kind IN ('api', 'rss', 'json')),
  base_url text NOT NULL,
  enabled boolean NOT NULL DEFAULT true,
  poll_interval_minutes integer NOT NULL DEFAULT 15 CHECK (poll_interval_minutes > 0),
  metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS organizations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name text NOT NULL,
  normalized_name text NOT NULL UNIQUE,
  domains text[] NOT NULL DEFAULT ARRAY[]::text[],
  enabled boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS organization_aliases (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id uuid NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  alias text NOT NULL,
  normalized_alias text NOT NULL,
  matching_mode text NOT NULL DEFAULT 'exact' CHECK (matching_mode IN ('exact', 'token', 'domain')),
  confidence_score smallint NOT NULL CHECK (confidence_score BETWEEN 0 AND 100),
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (organization_id, normalized_alias, matching_mode)
);

CREATE TABLE IF NOT EXISTS collection_runs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  source_id uuid NOT NULL REFERENCES sources(id),
  started_at timestamptz NOT NULL DEFAULT now(),
  finished_at timestamptz,
  status text NOT NULL DEFAULT 'running' CHECK (status IN ('running', 'succeeded', 'partial', 'failed')),
  fetched_count integer NOT NULL DEFAULT 0 CHECK (fetched_count >= 0),
  inserted_count integer NOT NULL DEFAULT 0 CHECK (inserted_count >= 0),
  error_message text,
  metadata jsonb NOT NULL DEFAULT '{}'::jsonb
);

CREATE TABLE IF NOT EXISTS observations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  source_id uuid NOT NULL REFERENCES sources(id),
  collection_run_id uuid REFERENCES collection_runs(id) ON DELETE SET NULL,
  source_event_id text,
  source_key text NOT NULL,
  fetched_at timestamptz NOT NULL DEFAULT now(),
  discovered_at timestamptz,
  published_at timestamptz,
  victim_name text NOT NULL,
  normalized_victim_name text NOT NULL,
  victim_domain text,
  threat_actor text,
  normalized_threat_actor text,
  title text,
  description text,
  source_url text,
  payload_hash char(64) NOT NULL,
  raw_payload jsonb NOT NULL DEFAULT '{}'::jsonb,
  is_historical boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (source_id, source_key)
);

CREATE TABLE IF NOT EXISTS claims (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  canonical_key text NOT NULL,
  victim_name text NOT NULL,
  normalized_victim_name text NOT NULL,
  victim_domain text,
  threat_actor text,
  normalized_threat_actor text,
  claimed_at timestamptz,
  first_seen_at timestamptz NOT NULL,
  last_seen_at timestamptz NOT NULL,
  verification_status text NOT NULL DEFAULT 'claimed'
    CHECK (verification_status IN ('claimed', 'multi_source_observed', 'officially_confirmed', 'disputed', 'refuted')),
  lifecycle_status text NOT NULL DEFAULT 'open'
    CHECK (lifecycle_status IN ('open', 'monitoring', 'closed')),
  evidence_version integer NOT NULL DEFAULT 1 CHECK (evidence_version > 0),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS claims_correlation_idx
  ON claims (normalized_victim_name, normalized_threat_actor, first_seen_at DESC);
CREATE INDEX IF NOT EXISTS claims_domain_idx
  ON claims (victim_domain, normalized_threat_actor, first_seen_at DESC)
  WHERE victim_domain IS NOT NULL;

CREATE TABLE IF NOT EXISTS claim_observations (
  claim_id uuid NOT NULL REFERENCES claims(id) ON DELETE CASCADE,
  observation_id uuid NOT NULL REFERENCES observations(id) ON DELETE CASCADE,
  linked_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (claim_id, observation_id),
  UNIQUE (observation_id)
);

CREATE TABLE IF NOT EXISTS organization_matches (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  claim_id uuid NOT NULL REFERENCES claims(id) ON DELETE CASCADE,
  organization_id uuid NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  matching_method text NOT NULL CHECK (matching_method IN ('domain_exact', 'name_exact', 'alias_exact', 'token', 'fuzzy')),
  confidence_score smallint NOT NULL CHECK (confidence_score BETWEEN 0 AND 100),
  review_status text NOT NULL DEFAULT 'pending'
    CHECK (review_status IN ('pending', 'accepted', 'rejected', 'auto_accepted')),
  evidence jsonb NOT NULL DEFAULT '{}'::jsonb,
  matched_at timestamptz NOT NULL DEFAULT now(),
  reviewed_at timestamptz,
  UNIQUE (claim_id, organization_id)
);

CREATE TABLE IF NOT EXISTS analyses (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  claim_id uuid NOT NULL REFERENCES claims(id) ON DELETE CASCADE,
  model_name text NOT NULL,
  model_digest text,
  prompt_version text NOT NULL,
  input_hash char(64) NOT NULL,
  output_payload jsonb NOT NULL,
  validation_status text NOT NULL CHECK (validation_status IN ('valid', 'invalid', 'fallback')),
  error_message text,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (claim_id, prompt_version, input_hash)
);

CREATE TABLE IF NOT EXISTS notification_outbox (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  claim_id uuid NOT NULL REFERENCES claims(id) ON DELETE CASCADE,
  organization_id uuid NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  channel text NOT NULL CHECK (channel IN ('webhook', 'email', 'teams')),
  notification_type text NOT NULL CHECK (notification_type IN ('new_claim', 'status_change', 'correction')),
  evidence_version integer NOT NULL CHECK (evidence_version > 0),
  deduplication_key text NOT NULL UNIQUE,
  payload jsonb NOT NULL,
  status text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'processing', 'sent', 'retry', 'dead_letter')),
  attempts integer NOT NULL DEFAULT 0 CHECK (attempts >= 0),
  available_at timestamptz NOT NULL DEFAULT now(),
  sent_at timestamptz,
  last_error text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS notification_outbox_dispatch_idx
  ON notification_outbox (status, available_at)
  WHERE status IN ('pending', 'retry');

CREATE TABLE IF NOT EXISTS notification_attempts (
  id bigserial PRIMARY KEY,
  notification_id uuid NOT NULL REFERENCES notification_outbox(id) ON DELETE CASCADE,
  attempted_at timestamptz NOT NULL DEFAULT now(),
  succeeded boolean NOT NULL,
  response_status integer,
  response_excerpt text,
  error_message text
);

INSERT INTO sources (id, slug, name, source_kind, base_url, enabled, metadata)
VALUES
  ('10000000-0000-4000-8000-000000000001', 'ransomware-live', 'ransomware.live', 'api', 'https://api.ransomware.live/v2', true, '{"priority":"primary"}'),
  ('10000000-0000-4000-8000-000000000002', 'ransomlook', 'RansomLook', 'api', 'https://www.ransomlook.io/api', true, '{"priority":"secondary"}'),
  ('10000000-0000-4000-8000-000000000003', 'frenchbreaches', 'FrenchBreaches', 'rss', 'https://frenchbreaches.com/', false, '{"priority":"experimental","reason":"rss_endpoint_pending_validation"}')
ON CONFLICT (slug) DO NOTHING;

INSERT INTO organizations (id, name, normalized_name, domains)
VALUES
  ('20000000-0000-4000-8000-000000000001', 'Aster Habitat [Synthetic]', 'aster habitat synthetic', ARRAY['aster-habitat.invalid']),
  ('20000000-0000-4000-8000-000000000002', 'Boreal Homes [Synthetic]', 'boreal homes synthetic', ARRAY['boreal-homes.invalid']),
  ('20000000-0000-4000-8000-000000000003', 'Cobalt Property Group [Synthetic]', 'cobalt property group synthetic', ARRAY['cobalt-property.invalid'])
ON CONFLICT (normalized_name) DO NOTHING;

INSERT INTO organization_aliases (organization_id, alias, normalized_alias, matching_mode, confidence_score)
VALUES
  ('20000000-0000-4000-8000-000000000001', 'Aster Habitat [Synthetic]', 'aster habitat synthetic', 'exact', 95),
  ('20000000-0000-4000-8000-000000000001', 'aster-habitat.invalid', 'aster-habitat.invalid', 'domain', 100),
  ('20000000-0000-4000-8000-000000000002', 'Boreal Homes [Synthetic]', 'boreal homes synthetic', 'exact', 95),
  ('20000000-0000-4000-8000-000000000002', 'boreal-homes.invalid', 'boreal-homes.invalid', 'domain', 100),
  ('20000000-0000-4000-8000-000000000003', 'Cobalt Property Group [Synthetic]', 'cobalt property group synthetic', 'exact', 95),
  ('20000000-0000-4000-8000-000000000003', 'CobaltProperty Group [Synthetic]', 'cobaltproperty group synthetic', 'exact', 90),
  ('20000000-0000-4000-8000-000000000003', 'cobalt-property.invalid', 'cobalt-property.invalid', 'domain', 100)
ON CONFLICT (organization_id, normalized_alias, matching_mode) DO NOTHING;

INSERT INTO schema_migrations (version)
VALUES ('001_initial_schema')
ON CONFLICT (version) DO NOTHING;

COMMIT;
