use std::error::Error;
use std::fmt::{Display, Formatter};

use serde::Serialize;
use sqlx::PgPool;
use uuid::Uuid;

use crate::chunker::chunk_text;
use crate::embed::{EmbedClient, EmbedError};
use crate::frontmatter::body_without_front_matter;

#[derive(Clone, Copy, Debug, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct IndexOutcome {
    pub episodes_indexed: usize,
    pub chunks_created: usize,
}

#[derive(Debug)]
enum IndexFailureKind {
    Database(sqlx::Error),
    Embedding(EmbedError),
}

#[derive(Debug)]
pub struct IndexFailure {
    pub outcome: IndexOutcome,
    kind: IndexFailureKind,
}

impl IndexFailure {
    fn database(outcome: IndexOutcome, error: sqlx::Error) -> Self {
        Self {
            outcome,
            kind: IndexFailureKind::Database(error),
        }
    }

    fn embedding(outcome: IndexOutcome, error: EmbedError) -> Self {
        Self {
            outcome,
            kind: IndexFailureKind::Embedding(error),
        }
    }

    pub fn is_embedding(&self) -> bool {
        matches!(self.kind, IndexFailureKind::Embedding(_))
    }
}

impl Display for IndexFailure {
    fn fmt(&self, formatter: &mut Formatter<'_>) -> std::fmt::Result {
        let detail = match &self.kind {
            IndexFailureKind::Database(error) => error.to_string(),
            IndexFailureKind::Embedding(error) => error.to_string(),
        };
        write!(
            formatter,
            "{detail} after indexing {} episodes and creating {} chunks",
            self.outcome.episodes_indexed, self.outcome.chunks_created
        )
    }
}

impl Error for IndexFailure {}

pub fn halfvec_literal(values: &[f32]) -> String {
    format!(
        "[{}]",
        values
            .iter()
            .map(f32::to_string)
            .collect::<Vec<_>>()
            .join(",")
    )
}

pub async fn index_pending(
    pool: &PgPool,
    embed_client: &EmbedClient,
) -> Result<IndexOutcome, IndexFailure> {
    let mut outcome = IndexOutcome::default();
    let episodes = sqlx::query_as::<_, (Uuid, String, Option<String>)>(
        "SELECT e.id, e.body_original, e.body_en FROM episodes e WHERE NOT EXISTS (SELECT 1 FROM chunks c WHERE c.episode_id = e.id) ORDER BY e.occurred_at, e.id LIMIT 500",
    )
    .fetch_all(pool)
    .await
    .map_err(|error| IndexFailure::database(outcome, error))?;

    for (episode_id, body_original, body_en) in episodes {
        let originals = chunk_text(body_without_front_matter(&body_original));
        let chunks = match &body_en {
            Some(english) if english.trim() != body_original.trim() => {
                chunk_text(body_without_front_matter(english))
            }
            _ => originals.clone(),
        };
        let mut embeddings = Vec::with_capacity(chunks.len());
        for batch in chunks.chunks(16) {
            let mut batch_embeddings = embed_client
                .embed(batch)
                .await
                .map_err(|error| IndexFailure::embedding(outcome, error))?;
            embeddings.append(&mut batch_embeddings);
        }

        let mut transaction = pool
            .begin()
            .await
            .map_err(|error| IndexFailure::database(outcome, error))?;
        let mut episode_chunks_created = 0;
        for (ord, (text, embedding)) in chunks.iter().zip(&embeddings).enumerate() {
            let embedding = halfvec_literal(embedding);
            let token_count = (text.chars().count() / 4) as i32;
            let original = originals.get(ord).unwrap_or(text);
            let result = sqlx::query(
                "INSERT INTO chunks (episode_id, ord, text_original, text_en, embedding, token_count, embed_model) VALUES ($1, $2, $3, $4, $5::halfvec, $6, $7) ON CONFLICT (episode_id, ord) DO NOTHING",
            )
            .bind(episode_id)
            .bind(ord as i32)
            .bind(original)
            .bind(text)
            .bind(embedding)
            .bind(token_count)
            .bind(embed_client.model())
            .execute(&mut *transaction)
            .await
            .map_err(|error| IndexFailure::database(outcome, error))?;
            episode_chunks_created += result.rows_affected() as usize;
        }
        transaction
            .commit()
            .await
            .map_err(|error| IndexFailure::database(outcome, error))?;
        outcome.episodes_indexed += 1;
        outcome.chunks_created += episode_chunks_created;
    }

    Ok(outcome)
}
