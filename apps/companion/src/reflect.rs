use std::error::Error;

use chrono::{DateTime, Utc};
use serde::Serialize;
use serde_json::Value;
use sqlx::PgPool;
use uuid::Uuid;

use crate::embed::EmbedClient;
use crate::indexer::halfvec_literal;
use crate::reason::{ReasonClient, ReasonError};

const EXTRACTOR_VERSION: &str = "reflect-v1";

const SYSTEM_PROMPT: &str = "You distill durable beliefs about one person from their notes, \
voice memos and activity. A belief is a higher-order statement about how they work, feel or \
decide, not a restatement of a single note. Answer with a JSON array only. Each item: \
{\"statement\": string, \"kind\": \"pattern\"|\"preference\"|\"state\", \"confidence\": \
number 0..1, \"evidence\": [episode ids the belief rests on]}. Two to five beliefs. Only use \
episode ids you were given. If the material supports nothing durable, answer [].";

#[derive(Debug, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ReflectOutcome {
    pub episodes_considered: usize,
    pub beliefs_formed: usize,
    pub beliefs_strengthened: usize,
    pub beliefs_superseded: usize,
    pub model: String,
}

async fn backfill_belief_embeddings(
    pool: &PgPool,
    embed: &EmbedClient,
) -> Result<(), Box<dyn Error + Send + Sync>> {
    let pending = sqlx::query_as::<_, (Uuid, String)>(
        "SELECT id, statement FROM beliefs WHERE embedding IS NULL LIMIT 64",
    )
    .fetch_all(pool)
    .await?;
    if pending.is_empty() {
        return Ok(());
    }
    let statements = pending
        .iter()
        .map(|(_, statement)| statement.clone())
        .collect::<Vec<_>>();
    let embeddings = embed.embed(&statements).await?;
    for ((id, _), embedding) in pending.iter().zip(embeddings) {
        sqlx::query("UPDATE beliefs SET embedding = $2::halfvec WHERE id = $1")
            .bind(id)
            .bind(halfvec_literal(&embedding))
            .execute(pool)
            .await?;
    }
    Ok(())
}

pub async fn reflect_run(
    pool: &PgPool,
    embed: &EmbedClient,
    reason: &ReasonClient,
) -> Result<ReflectOutcome, Box<dyn Error + Send + Sync>> {
    if !reason.configured() {
        return Err(Box::new(ReasonError::unconfigured()));
    }
    backfill_belief_embeddings(pool, embed).await?;

    let episodes = sqlx::query_as::<_, (Uuid, DateTime<Utc>, String, String)>(
        "SELECT id, occurred_at, title, left(body_original, 1200) FROM episodes ORDER BY ingested_at DESC LIMIT 20",
    )
    .fetch_all(pool)
    .await?;
    let mut outcome = ReflectOutcome {
        episodes_considered: episodes.len(),
        beliefs_formed: 0,
        beliefs_strengthened: 0,
        beliefs_superseded: 0,
        model: reason.describe(),
    };
    if episodes.is_empty() {
        return Ok(outcome);
    }

    let material = episodes
        .iter()
        .map(|(id, occurred_at, title, body)| {
            format!(
                "episode {id} ({}) {title}\n{body}",
                occurred_at.format("%Y-%m-%d")
            )
        })
        .collect::<Vec<_>>()
        .join("\n\n");
    let known_ids = episodes.iter().map(|row| row.0).collect::<Vec<_>>();

    let candidates = reason.complete_array(SYSTEM_PROMPT, &material).await?;

    for candidate in candidates.as_array().into_iter().flatten() {
        let Some(statement) = candidate
            .get("statement")
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|statement| statement.len() > 10)
        else {
            continue;
        };
        let kind = candidate
            .get("kind")
            .and_then(Value::as_str)
            .filter(|kind| ["pattern", "preference", "state"].contains(kind))
            .unwrap_or("pattern");
        let confidence = candidate
            .get("confidence")
            .and_then(Value::as_f64)
            .unwrap_or(0.5)
            .clamp(0.0, 1.0) as f32;
        let evidence = candidate
            .get("evidence")
            .and_then(Value::as_array)
            .map(|values| {
                values
                    .iter()
                    .filter_map(Value::as_str)
                    .filter_map(|value| Uuid::parse_str(value).ok())
                    .filter(|id| known_ids.contains(id))
                    .collect::<Vec<_>>()
            })
            .unwrap_or_default();
        if evidence.is_empty() {
            continue;
        }

        let embedding = halfvec_literal(&embed.embed(&[statement.to_owned()]).await?.remove(0));
        let nearest = sqlx::query_as::<_, (Uuid, f64)>(
            "SELECT id, 1 - (embedding <=> $1::halfvec) AS similarity FROM beliefs WHERE status = 'active' AND embedding IS NOT NULL ORDER BY embedding <=> $1::halfvec LIMIT 1",
        )
        .bind(&embedding)
        .fetch_optional(pool)
        .await?;

        match nearest {
            Some((existing_id, similarity)) if similarity >= 0.90 => {
                sqlx::query(
                    "UPDATE beliefs SET last_confirmed = now(), stability = stability + 1, evidence_episode_ids = ARRAY(SELECT DISTINCT unnest(evidence_episode_ids || $2::uuid[])) WHERE id = $1",
                )
                .bind(existing_id)
                .bind(&evidence)
                .execute(pool)
                .await?;
                outcome.beliefs_strengthened += 1;
            }
            Some((existing_id, similarity)) if similarity >= 0.80 => {
                let new_id = sqlx::query_scalar::<_, Uuid>(
                    "INSERT INTO beliefs (statement, kind, confidence, evidence_episode_ids, extractor_version, embedding) VALUES ($1, $2, $3, $4, $5, $6::halfvec) RETURNING id",
                )
                .bind(statement)
                .bind(kind)
                .bind(confidence)
                .bind(&evidence)
                .bind(EXTRACTOR_VERSION)
                .bind(&embedding)
                .fetch_one(pool)
                .await?;
                sqlx::query(
                    "UPDATE beliefs SET status = 'superseded', superseded_by = $2 WHERE id = $1",
                )
                .bind(existing_id)
                .bind(new_id)
                .execute(pool)
                .await?;
                outcome.beliefs_superseded += 1;
                outcome.beliefs_formed += 1;
            }
            _ => {
                sqlx::query(
                    "INSERT INTO beliefs (statement, kind, confidence, evidence_episode_ids, extractor_version, embedding) VALUES ($1, $2, $3, $4, $5, $6::halfvec)",
                )
                .bind(statement)
                .bind(kind)
                .bind(confidence)
                .bind(&evidence)
                .bind(EXTRACTOR_VERSION)
                .bind(&embedding)
                .execute(pool)
                .await?;
                outcome.beliefs_formed += 1;
            }
        }
    }

    sqlx::query(
        "INSERT INTO reflections (episodes_considered, beliefs_formed, model) VALUES ($1, $2, $3)",
    )
    .bind(outcome.episodes_considered as i32)
    .bind(outcome.beliefs_formed as i32)
    .bind(&outcome.model)
    .execute(pool)
    .await?;

    Ok(outcome)
}
