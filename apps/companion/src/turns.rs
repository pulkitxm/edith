use sqlx::PgPool;
use uuid::Uuid;

use crate::retrieve::RetrievedItem;

pub struct RetrievedChunk {
    pub item_type: String,
    pub chunk_id: Uuid,
    pub episode_id: Uuid,
    pub rank: i32,
    pub score_vec: Option<f32>,
    pub score_text: Option<f32>,
    pub score_graph: Option<f32>,
    pub score_recency: Option<f32>,
    pub score_salience: Option<f32>,
    pub score_rerank: Option<f32>,
    pub score_fused: Option<f32>,
    pub was_cited: bool,
}

impl RetrievedChunk {
    pub fn from_item(item: &RetrievedItem, rank: i32, was_cited: bool) -> Self {
        Self {
            item_type: item.item_type.clone(),
            chunk_id: item.item_id,
            episode_id: item.episode_id.unwrap_or(item.item_id),
            rank,
            score_vec: item.scores.vector,
            score_text: item.scores.text,
            score_graph: item.scores.graph,
            score_recency: item.scores.recency,
            score_salience: item.scores.salience,
            score_rerank: item.scores.rerank,
            score_fused: Some(item.scores.fused),
            was_cited,
        }
    }
}

#[derive(Default)]
pub struct TurnRecord<'a> {
    pub kind: &'a str,
    pub query: &'a str,
    pub model: Option<&'a str>,
    pub persona: Option<&'a str>,
    pub prompt_version: Option<&'a str>,
    pub grounding_score: Option<f32>,
    pub abstained: bool,
    pub latency_ms: i32,
}

pub async fn log_turn_record(
    pool: &PgPool,
    record: TurnRecord<'_>,
    retrieved: &[RetrievedChunk],
) -> Option<Uuid> {
    let turn_id = match sqlx::query_scalar::<_, Uuid>(
        "INSERT INTO turns (kind, query, model, latency_ms, persona, prompt_version, grounding_score, abstained) VALUES ($1, $2, $3, $4, $5, $6, $7, $8) RETURNING id",
    )
    .bind(record.kind)
    .bind(record.query)
    .bind(record.model)
    .bind(record.latency_ms)
    .bind(record.persona)
    .bind(record.prompt_version)
    .bind(record.grounding_score)
    .bind(record.abstained)
    .fetch_one(pool)
    .await
    {
        Ok(turn_id) => turn_id,
        Err(error) => {
            eprintln!("turn logging failed: {error}");
            return None;
        }
    };

    for chunk in retrieved {
        if let Err(error) = sqlx::query(
            "INSERT INTO retrievals (turn_id, item_type, chunk_id, episode_id, rank, score_vec, score_text, score_graph, score_recency, score_salience, score_rerank, score_fused, was_cited) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13)",
        )
        .bind(turn_id)
        .bind(&chunk.item_type)
        .bind(chunk.chunk_id)
        .bind(chunk.episode_id)
        .bind(chunk.rank)
        .bind(chunk.score_vec)
        .bind(chunk.score_text)
        .bind(chunk.score_graph)
        .bind(chunk.score_recency)
        .bind(chunk.score_salience)
        .bind(chunk.score_rerank)
        .bind(chunk.score_fused)
        .bind(chunk.was_cited)
        .execute(pool)
        .await
        {
            eprintln!("retrieval logging failed: {error}");
            return Some(turn_id);
        }
    }
    Some(turn_id)
}

pub async fn log_turn(
    pool: &PgPool,
    kind: &str,
    query: &str,
    model: Option<&str>,
    latency_ms: i32,
    retrieved: &[RetrievedChunk],
) {
    log_turn_record(
        pool,
        TurnRecord {
            kind,
            query,
            model,
            latency_ms,
            ..TurnRecord::default()
        },
        retrieved,
    )
    .await;
}

pub fn latency_since(started: std::time::Instant) -> i32 {
    i32::try_from(started.elapsed().as_millis()).unwrap_or(i32::MAX)
}
