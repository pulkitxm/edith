use std::error::Error;

use chrono::{DateTime, Utc};
use serde::Serialize;
use sqlx::PgPool;

use crate::core_memory::trim_words;
use crate::persona;
use crate::reason::{ReasonClient, ReasonError};

const SYSTEM_PROMPT: &str = "You keep a short note for one lens of a companion system, recording \
what that lens has learned about being useful to this particular person in its role. Not what it \
knows about them, the shared memory already holds that: what works when it speaks to them. When \
they take a nudge and when they ignore one. When they want to be left alone. What kind of \
pushback lands. You are given the note as it stands and recent exchanges with that lens. Rewrite \
the note. At most 80 words, plain sentences, no headings. Change nothing that the exchanges do \
not actually bear on.";

#[derive(Debug, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LensOutcome {
    pub lenses_rewritten: usize,
    pub turns_read: usize,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LensRow {
    pub persona: String,
    pub content: String,
    pub updated_at: DateTime<Utc>,
    pub updated_by: String,
}

pub async fn load(pool: &PgPool, persona_id: &str) -> String {
    sqlx::query_scalar::<_, String>("SELECT content FROM persona_lenses WHERE persona = $1")
        .bind(persona_id)
        .fetch_optional(pool)
        .await
        .ok()
        .flatten()
        .unwrap_or_default()
}

pub async fn list(pool: &PgPool) -> Result<Vec<LensRow>, sqlx::Error> {
    let rows = sqlx::query_as::<_, (String, String, DateTime<Utc>, String)>(
        "SELECT persona, content, updated_at, updated_by FROM persona_lenses ORDER BY persona",
    )
    .fetch_all(pool)
    .await?;
    Ok(rows
        .into_iter()
        .map(|(persona, content, updated_at, updated_by)| LensRow {
            persona,
            content,
            updated_at,
            updated_by,
        })
        .collect())
}

pub async fn rewrite(
    pool: &PgPool,
    reason: &ReasonClient,
) -> Result<LensOutcome, Box<dyn Error + Send + Sync>> {
    if !reason.configured() {
        return Err(Box::new(ReasonError::unconfigured()));
    }
    let mut outcome = LensOutcome::default();

    for lens in persona::all() {
        type Row = (String, Option<f32>, bool, DateTime<Utc>);
        let turns = sqlx::query_as::<_, Row>(
            "SELECT query, grounding_score, abstained, created_at FROM turns WHERE persona = $1 AND created_at > now() - interval '7 days' ORDER BY created_at DESC LIMIT 25",
        )
        .bind(&lens.id)
        .fetch_all(pool)
        .await?;
        if turns.len() < 3 {
            continue;
        }
        outcome.turns_read += turns.len();

        let current = load(pool, &lens.id).await;
        let current = if current.trim().is_empty() {
            "The note is empty; write it from scratch.".to_owned()
        } else {
            current
        };
        let exchanges = turns
            .iter()
            .map(|(query, grounding, abstained, created_at)| {
                format!(
                    "- {} they asked: {query} (grounding {:.2}{})",
                    created_at.format("%Y-%m-%d"),
                    grounding.unwrap_or(0.0),
                    if *abstained {
                        ", the lens declined to answer"
                    } else {
                        ""
                    }
                )
            })
            .collect::<Vec<_>>()
            .join("\n");
        let prompt = format!(
            "Lens: {}\n\nThe note as it stands:\n{current}\n\nRecent exchanges with this lens:\n{exchanges}",
            lens.label
        );
        let Ok(answer) = reason.complete(SYSTEM_PROMPT, &prompt).await else {
            continue;
        };
        let content = trim_words(answer.trim(), 90);
        if content.len() < 20 {
            continue;
        }
        sqlx::query(
            "INSERT INTO persona_lenses (persona, content) VALUES ($1, $2) ON CONFLICT (persona) DO UPDATE SET content = EXCLUDED.content, updated_at = now(), updated_by = 'nightly'",
        )
        .bind(&lens.id)
        .bind(&content)
        .execute(pool)
        .await?;
        outcome.lenses_rewritten += 1;
    }
    Ok(outcome)
}
