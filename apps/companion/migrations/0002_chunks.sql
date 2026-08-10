CREATE TABLE chunks (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  episode_id uuid NOT NULL REFERENCES episodes(id) ON DELETE CASCADE,
  ord int NOT NULL,
  text_original text NOT NULL,
  text_en text NOT NULL,
  t_start_s real,
  t_end_s real,
  embedding halfvec(512),
  tsv tsvector GENERATED ALWAYS AS (to_tsvector('english', text_en)) STORED,
  salience real,
  token_count int,
  embed_model text,
  UNIQUE (episode_id, ord)
);

CREATE INDEX chunks_embedding_idx ON chunks USING hnsw (embedding halfvec_cosine_ops);
CREATE INDEX chunks_tsv_idx ON chunks USING gin (tsv);
CREATE INDEX chunks_episode_id_idx ON chunks(episode_id);
