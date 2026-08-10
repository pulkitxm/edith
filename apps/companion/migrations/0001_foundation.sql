CREATE EXTENSION IF NOT EXISTS vector;

CREATE TABLE sources (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  kind text NOT NULL,
  uri text NOT NULL,
  sha256 text NOT NULL UNIQUE,
  bytes bigint NOT NULL,
  imported_at timestamptz NOT NULL DEFAULT now(),
  connector_meta jsonb NOT NULL DEFAULT '{}'
);

CREATE TABLE episodes (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  source_id uuid NOT NULL REFERENCES sources(id),
  occurred_at timestamptz NOT NULL,
  ingested_at timestamptz NOT NULL DEFAULT now(),
  kind text NOT NULL,
  title text NOT NULL,
  body_original text NOT NULL,
  body_en text,
  langs text[] NOT NULL DEFAULT '{}',
  script text,
  translated_by text,
  media_ref text,
  duration_s real,
  meta jsonb NOT NULL DEFAULT '{}'
);

CREATE TABLE claims (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  episode_id uuid NOT NULL REFERENCES episodes(id),
  statement text NOT NULL,
  subject text,
  predicate text,
  object text,
  asserted_at timestamptz NOT NULL,
  about_period tstzrange,
  hedging text,
  claim_type text NOT NULL,
  testable boolean NOT NULL DEFAULT false,
  expected_observable jsonb
);

CREATE TABLE observations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  source text NOT NULL,
  observed_at timestamptz NOT NULL,
  kind text NOT NULL,
  payload jsonb NOT NULL DEFAULT '{}',
  entity_ids uuid[] NOT NULL DEFAULT '{}'
);

CREATE TABLE facts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  subject_id uuid,
  predicate text NOT NULL,
  object_id uuid,
  object_literal text,
  valid_from timestamptz,
  valid_to timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  expired_at timestamptz,
  confidence real,
  superseded_by uuid,
  source_episode_ids uuid[] NOT NULL DEFAULT '{}',
  extractor_version text
);

CREATE TABLE IF NOT EXISTS schema_migrations (
  version text PRIMARY KEY,
  applied_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX episodes_occurred_at_idx ON episodes(occurred_at);
CREATE INDEX episodes_source_id_idx ON episodes(source_id);
CREATE INDEX claims_episode_id_idx ON claims(episode_id);
CREATE INDEX observations_observed_at_idx ON observations(observed_at);
CREATE INDEX observations_kind_idx ON observations(kind);
