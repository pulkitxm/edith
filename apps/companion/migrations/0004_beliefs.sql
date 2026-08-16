CREATE TABLE beliefs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  statement text NOT NULL,
  kind text NOT NULL,
  confidence real NOT NULL,
  stability real NOT NULL DEFAULT 0,
  corroboration text NOT NULL DEFAULT 'self_reported',
  first_formed timestamptz NOT NULL DEFAULT now(),
  last_confirmed timestamptz NOT NULL DEFAULT now(),
  superseded_by uuid REFERENCES beliefs(id),
  evidence_episode_ids uuid[] NOT NULL DEFAULT '{}',
  counter_evidence_episode_ids uuid[] NOT NULL DEFAULT '{}',
  extractor_version text NOT NULL,
  status text NOT NULL DEFAULT 'active'
);

CREATE INDEX beliefs_status_idx ON beliefs(status);
CREATE INDEX beliefs_first_formed_idx ON beliefs(first_formed);

CREATE TABLE reflections (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  ran_at timestamptz NOT NULL DEFAULT now(),
  episodes_considered int NOT NULL,
  beliefs_formed int NOT NULL,
  model text NOT NULL
);
