BEGIN;

CREATE EXTENSION IF NOT EXISTS unaccent;

CREATE OR REPLACE FUNCTION normalize_match_text(input_value text)
RETURNS text
LANGUAGE sql
STABLE
STRICT
PARALLEL SAFE
AS $$
  SELECT nullif(
    trim(
      regexp_replace(
        regexp_replace(
          lower(unaccent('unaccent', input_value)),
          '[^a-z0-9]+',
          ' ',
          'g'
        ),
        '[[:space:]]+',
        ' ',
        'g'
      )
    ),
    ''
  );
$$;

CREATE OR REPLACE FUNCTION normalize_threat_actor(input_value text)
RETURNS text
LANGUAGE sql
STABLE
STRICT
PARALLEL SAFE
AS $$
  SELECT normalize_match_text(input_value);
$$;

CREATE OR REPLACE FUNCTION normalize_domain(input_value text)
RETURNS text
LANGUAGE plpgsql
IMMUTABLE
STRICT
PARALLEL SAFE
AS $$
DECLARE
  normalized text := lower(trim(input_value));
BEGIN
  IF normalized ~ '^[a-z][a-z0-9+.-]*://' THEN
    normalized := regexp_replace(normalized, '^[a-z][a-z0-9+.-]*://', '');
  END IF;

  IF position('@' IN normalized) > 0 THEN
    RETURN NULL;
  END IF;

  normalized := regexp_replace(normalized, '[/#?].*$', '');
  normalized := regexp_replace(normalized, ':[0-9]+$', '');
  normalized := regexp_replace(normalized, '^\*\.', '');
  normalized := trim(both '.' FROM normalized);

  IF normalized = ''
     OR length(normalized) > 253
     OR normalized !~ '^[a-z0-9.-]+$'
     OR normalized !~ '[.]'
     OR normalized ~ '^[0-9.]+$'
     OR EXISTS (
       SELECT 1
       FROM regexp_split_to_table(normalized, '[.]') AS label
       WHERE label = ''
          OR length(label) > 63
          OR label !~ '^[a-z0-9]([a-z0-9-]*[a-z0-9])?$'
     )
  THEN
    RETURN NULL;
  END IF;

  RETURN normalized;
END;
$$;

CREATE OR REPLACE FUNCTION domain_matches_registered(
  candidate_value text,
  approved_registered_domain text
)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
AS $$
  SELECT CASE
    WHEN normalize_domain(candidate_value) IS NULL
      OR normalize_domain(approved_registered_domain) IS NULL
      THEN false
    ELSE normalize_domain(candidate_value) = normalize_domain(approved_registered_domain)
      OR right(
        normalize_domain(candidate_value),
        length(normalize_domain(approved_registered_domain)) + 1
      ) = '.' || normalize_domain(approved_registered_domain)
  END;
$$;

CREATE OR REPLACE FUNCTION extract_approved_registered_domain(
  candidate_value text,
  approved_domains text[]
)
RETURNS text
LANGUAGE sql
IMMUTABLE
STRICT
PARALLEL SAFE
AS $$
  SELECT normalize_domain(approved_domain)
  FROM unnest(approved_domains) AS approved_domain
  WHERE domain_matches_registered(candidate_value, approved_domain)
  ORDER BY length(normalize_domain(approved_domain)) DESC
  LIMIT 1;
$$;

INSERT INTO schema_migrations (version)
VALUES ('004_matching_normalization')
ON CONFLICT (version) DO NOTHING;

COMMIT;
