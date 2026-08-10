CREATE TABLE signals (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  episode_id uuid NOT NULL REFERENCES episodes(id) ON DELETE CASCADE,
  t_start_s real NOT NULL,
  t_end_s real NOT NULL,
  kind text NOT NULL,
  value real NOT NULL,
  extractor text NOT NULL
);

CREATE INDEX signals_episode_id_idx ON signals(episode_id);
CREATE INDEX signals_kind_idx ON signals(kind);
