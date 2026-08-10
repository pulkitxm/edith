ALTER TABLE observations ADD COLUMN dedupe_key text;

CREATE UNIQUE INDEX observations_dedupe_key_idx ON observations(dedupe_key) WHERE dedupe_key IS NOT NULL;
