ALTER TABLE chunks DROP COLUMN tsv;

ALTER TABLE chunks ADD COLUMN tsv tsvector GENERATED ALWAYS AS (
  to_tsvector('english', text_en || ' ' || text_original)
) STORED;

CREATE INDEX chunks_tsv_idx ON chunks USING gin (tsv);
