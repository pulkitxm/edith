CREATE TABLE entities (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  kind text NOT NULL,
  canonical_name text NOT NULL,
  aliases text[] NOT NULL DEFAULT '{}',
  embedding halfvec(512),
  first_seen timestamptz NOT NULL DEFAULT now(),
  last_seen timestamptz NOT NULL DEFAULT now(),
  mention_count int NOT NULL DEFAULT 0,
  UNIQUE (kind, canonical_name)
);

CREATE INDEX entities_embedding_idx ON entities USING hnsw (embedding halfvec_cosine_ops);
CREATE INDEX entities_aliases_idx ON entities USING gin (aliases);

CREATE TABLE entity_mentions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  entity_id uuid NOT NULL REFERENCES entities(id) ON DELETE CASCADE,
  episode_id uuid NOT NULL REFERENCES episodes(id) ON DELETE CASCADE,
  surface text NOT NULL,
  script text,
  noticed_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (entity_id, episode_id, surface)
);

CREATE INDEX entity_mentions_episode_idx ON entity_mentions(episode_id);

CREATE TABLE belief_links (
  from_id uuid NOT NULL REFERENCES beliefs(id) ON DELETE CASCADE,
  to_id uuid NOT NULL REFERENCES beliefs(id) ON DELETE CASCADE,
  relation text NOT NULL,
  PRIMARY KEY (from_id, to_id, relation)
);

CREATE TABLE core_memory (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  section text NOT NULL UNIQUE,
  content text NOT NULL,
  tokens int NOT NULL DEFAULT 0,
  updated_at timestamptz NOT NULL DEFAULT now(),
  updated_by text NOT NULL DEFAULT 'nightly'
);

CREATE TABLE hypotheses (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  statement text NOT NULL,
  causal_claim text,
  mechanism text NOT NULL,
  status text NOT NULL DEFAULT 'proposed',
  prior real NOT NULL DEFAULT 0.5,
  posterior real NOT NULL DEFAULT 0.5,
  formed_at timestamptz NOT NULL DEFAULT now(),
  last_tested_at timestamptz,
  test_count int NOT NULL DEFAULT 0,
  supporting_ids uuid[] NOT NULL DEFAULT '{}',
  refuting_ids uuid[] NOT NULL DEFAULT '{}',
  alternative_explanations text[] NOT NULL DEFAULT '{}',
  superseded_by uuid REFERENCES hypotheses(id),
  generated_by text NOT NULL DEFAULT 'reflection',
  embedding halfvec(512)
);

CREATE INDEX hypotheses_status_idx ON hypotheses(status);
CREATE INDEX hypotheses_embedding_idx ON hypotheses USING hnsw (embedding halfvec_cosine_ops);

CREATE TABLE hypothesis_revisions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  hypothesis_id uuid NOT NULL REFERENCES hypotheses(id) ON DELETE CASCADE,
  at timestamptz NOT NULL DEFAULT now(),
  posterior real NOT NULL,
  status text NOT NULL,
  trigger_prediction_id uuid,
  note text NOT NULL DEFAULT ''
);

CREATE INDEX hypothesis_revisions_hypothesis_idx ON hypothesis_revisions(hypothesis_id, at);

CREATE TABLE predictions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  hypothesis_id uuid NOT NULL REFERENCES hypotheses(id) ON DELETE CASCADE,
  statement text NOT NULL,
  window_start timestamptz NOT NULL,
  window_end timestamptz NOT NULL,
  observable text NOT NULL,
  resolved_at timestamptz,
  outcome text
);

CREATE INDEX predictions_window_end_idx ON predictions(window_end) WHERE resolved_at IS NULL;

CREATE TABLE commitments (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  claim_id uuid NOT NULL REFERENCES claims(id) ON DELETE CASCADE,
  stated_at timestamptz NOT NULL,
  due_by timestamptz NOT NULL,
  observable jsonb NOT NULL DEFAULT '{}',
  status text NOT NULL DEFAULT 'open',
  resolved_at timestamptz,
  resolution_evidence uuid[] NOT NULL DEFAULT '{}',
  user_override text
);

CREATE INDEX commitments_status_idx ON commitments(status, due_by);
CREATE UNIQUE INDEX commitments_claim_idx ON commitments(claim_id);

CREATE TABLE discrepancies (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  claim_id uuid NOT NULL REFERENCES claims(id) ON DELETE CASCADE,
  observation_ids uuid[] NOT NULL DEFAULT '{}',
  kind text NOT NULL,
  magnitude real NOT NULL DEFAULT 0,
  detected_at timestamptz NOT NULL DEFAULT now(),
  user_response text,
  dismissed boolean NOT NULL DEFAULT false
);

CREATE INDEX discrepancies_detected_at_idx ON discrepancies(detected_at);

CREATE TABLE calibrations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  claim_id uuid NOT NULL REFERENCES claims(id) ON DELETE CASCADE,
  outcome_ids uuid[] NOT NULL DEFAULT '{}',
  direction text NOT NULL,
  magnitude real NOT NULL DEFAULT 0,
  domain text NOT NULL DEFAULT 'general',
  scored_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX calibrations_domain_idx ON calibrations(domain, direction);
CREATE UNIQUE INDEX calibrations_claim_idx ON calibrations(claim_id);

CREATE TABLE open_questions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  question text NOT NULL,
  motive text NOT NULL,
  target_kind text NOT NULL,
  target_id uuid,
  topic text NOT NULL DEFAULT 'general',
  expected_gain real NOT NULL DEFAULT 0,
  sensitivity smallint NOT NULL DEFAULT 0,
  created_at timestamptz NOT NULL DEFAULT now(),
  asked_at timestamptz,
  answered_at timestamptz,
  answer_episode_id uuid REFERENCES episodes(id),
  resolution text,
  status text NOT NULL DEFAULT 'pending'
);

CREATE INDEX open_questions_status_idx ON open_questions(status, expected_gain DESC);

CREATE TABLE muted_topics (
  topic text PRIMARY KEY,
  muted_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE persona_lenses (
  persona text PRIMARY KEY,
  content text NOT NULL DEFAULT '',
  updated_at timestamptz NOT NULL DEFAULT now(),
  updated_by text NOT NULL DEFAULT 'nightly'
);

CREATE TABLE machines (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name text NOT NULL UNIQUE,
  transport text NOT NULL,
  endpoint text NOT NULL DEFAULT '',
  added_at timestamptz NOT NULL DEFAULT now(),
  last_seen timestamptz,
  os text,
  arch text,
  docker_version text,
  compose_version text,
  gpu_vendor text,
  gpu_model text,
  vram_mb int,
  cpu_cores int,
  ram_mb int,
  disk_free_mb int,
  capabilities jsonb NOT NULL DEFAULT '{}',
  profile text,
  profile_override text,
  status text NOT NULL DEFAULT 'unknown'
);

CREATE TABLE placements (
  machine_id uuid NOT NULL REFERENCES machines(id) ON DELETE CASCADE,
  service text NOT NULL,
  enabled boolean NOT NULL DEFAULT true,
  port_map jsonb NOT NULL DEFAULT '{}',
  notes text NOT NULL DEFAULT '',
  PRIMARY KEY (machine_id, service)
);

CREATE TABLE evals (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  suite text NOT NULL,
  ran_at timestamptz NOT NULL DEFAULT now(),
  model text NOT NULL,
  cases int NOT NULL,
  passed int NOT NULL,
  detail jsonb NOT NULL DEFAULT '[]'
);

CREATE INDEX evals_ran_at_idx ON evals(ran_at);

ALTER TABLE turns ADD COLUMN persona text;
ALTER TABLE turns ADD COLUMN prompt_version text;
ALTER TABLE turns ADD COLUMN grounding_score real;
ALTER TABLE turns ADD COLUMN abstained boolean NOT NULL DEFAULT false;
ALTER TABLE turns ADD COLUMN tokens jsonb;

ALTER TABLE retrievals ADD COLUMN item_type text NOT NULL DEFAULT 'chunk';
ALTER TABLE retrievals ADD COLUMN score_graph real;
ALTER TABLE retrievals ADD COLUMN score_recency real;
ALTER TABLE retrievals ADD COLUMN score_salience real;
ALTER TABLE retrievals ADD COLUMN score_rerank real;
ALTER TABLE retrievals ADD COLUMN feedback smallint;

ALTER TABLE signals ADD COLUMN zscore real;
ALTER TABLE signals ADD COLUMN baseline_window text;
ALTER TABLE signals ADD COLUMN confidence real;
ALTER TABLE signals ADD COLUMN context_bucket text NOT NULL DEFAULT 'default';

CREATE INDEX signals_context_idx ON signals(context_bucket, kind);

ALTER TABLE claims ADD COLUMN observation_ids uuid[] NOT NULL DEFAULT '{}';

ALTER TABLE episodes ADD COLUMN persona text;

CREATE INDEX chunks_salience_idx ON chunks(salience DESC NULLS LAST);
