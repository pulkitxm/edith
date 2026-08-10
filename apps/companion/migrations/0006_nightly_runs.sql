CREATE TABLE nightly_runs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  started_at timestamptz NOT NULL DEFAULT now(),
  finished_at timestamptz,
  ok boolean NOT NULL DEFAULT false,
  steps jsonb NOT NULL DEFAULT '[]'
);

CREATE INDEX nightly_runs_started_at_idx ON nightly_runs(started_at);
