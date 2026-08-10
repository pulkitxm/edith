ALTER TABLE beliefs ADD COLUMN embedding halfvec(512);

CREATE INDEX beliefs_embedding_idx ON beliefs USING hnsw (embedding halfvec_cosine_ops);
