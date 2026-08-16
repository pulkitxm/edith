CREATE TABLE turns (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  kind text NOT NULL,
  query text NOT NULL,
  model text,
  latency_ms int NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX turns_created_at_idx ON turns(created_at);

CREATE TABLE retrievals (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  turn_id uuid NOT NULL REFERENCES turns(id) ON DELETE CASCADE,
  chunk_id uuid NOT NULL,
  episode_id uuid NOT NULL,
  rank int NOT NULL,
  score_vec real,
  score_text real,
  score_fused real,
  was_cited boolean NOT NULL DEFAULT false
);

CREATE INDEX retrievals_turn_id_idx ON retrievals(turn_id);
