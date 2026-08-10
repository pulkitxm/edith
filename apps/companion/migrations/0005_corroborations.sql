CREATE TABLE corroborations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  claim_id uuid NOT NULL REFERENCES claims(id),
  verdict text NOT NULL,
  note text NOT NULL,
  observation_ids uuid[] NOT NULL DEFAULT '{}',
  checked_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX corroborations_claim_id_idx ON corroborations(claim_id);
