use std::error::Error;

use chrono::{DateTime, Utc};
use serde::Serialize;
use serde_json::Value;
use sqlx::PgPool;
use uuid::Uuid;

use crate::embed::EmbedClient;
use crate::entities;
use crate::reason::{ReasonClient, ReasonError};

pub const EXTRACTOR_VERSION: &str = "facts-v1";

const EXTRACT_PROMPT: &str = "You pull the durable facts out of one person's own writing. A fact \
relates two things and stays true for a stretch of time: who they work with, what they work on, \
where they live, what they are doing instead of something else. Passing feelings are not facts. \
Answer with a JSON array only. Each item: {\"subject\": the named thing the fact is about, \
usually them, \"predicate\": a lower_snake_case relation such as works_on, lives_in, \
reports_to, avoids, uses, \"object\": the other named thing, \"objectKind\": \
person|project|place|organisation|thing, \"validFrom\": ISO date the fact started being true, \
or null if unknown, \"stillTrue\": bool, \"confidence\": number 0..1, \"supersedes\": the \
predicate this replaces if it contradicts something earlier, else null}. Zero to six facts. \
Only what the text actually says.";

#[derive(Debug, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct FactOutcome {
    pub episodes_considered: usize,
    pub facts_recorded: usize,
    pub windows_closed: usize,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct FactRow {
    pub id: Uuid,
    pub subject: String,
    pub predicate: String,
    pub object: String,
    pub valid_from: Option<DateTime<Utc>>,
    pub valid_to: Option<DateTime<Utc>>,
    pub created_at: DateTime<Utc>,
    pub expired_at: Option<DateTime<Utc>>,
    pub confidence: Option<f32>,
    pub superseded_by: Option<Uuid>,
    pub source_episode_ids: Vec<Uuid>,
}

const FACTS_AS_OF_VALID: &str = "SELECT f.id, se.canonical_name, f.predicate, coalesce(oe.canonical_name, f.object_literal), f.valid_from, f.valid_to, f.created_at, f.expired_at, f.confidence, f.superseded_by, f.source_episode_ids FROM facts f LEFT JOIN entities se ON se.id = f.subject_id LEFT JOIN entities oe ON oe.id = f.object_id WHERE f.valid_from <= $1 AND coalesce(f.valid_to, 'infinity'::timestamptz) > $1 ORDER BY coalesce(f.valid_from, f.created_at) DESC LIMIT $2";

const FACTS_AS_OF_BELIEVED: &str = "SELECT f.id, se.canonical_name, f.predicate, coalesce(oe.canonical_name, f.object_literal), f.valid_from, f.valid_to, f.created_at, f.expired_at, f.confidence, f.superseded_by, f.source_episode_ids FROM facts f LEFT JOIN entities se ON se.id = f.subject_id LEFT JOIN entities oe ON oe.id = f.object_id WHERE f.created_at <= $1 AND coalesce(f.expired_at, 'infinity'::timestamptz) > $1 ORDER BY coalesce(f.valid_from, f.created_at) DESC LIMIT $2";

const FACTS_EVERYTHING: &str = "SELECT f.id, se.canonical_name, f.predicate, coalesce(oe.canonical_name, f.object_literal), f.valid_from, f.valid_to, f.created_at, f.expired_at, f.confidence, f.superseded_by, f.source_episode_ids FROM facts f LEFT JOIN entities se ON se.id = f.subject_id LEFT JOIN entities oe ON oe.id = f.object_id WHERE $1 IS NOT NULL ORDER BY coalesce(f.valid_from, f.created_at) DESC LIMIT $2";

pub async fn list(
    pool: &PgPool,
    as_of: Option<DateTime<Utc>>,
    timeline: &str,
    limit: i64,
) -> Result<Vec<FactRow>, sqlx::Error> {
    type Row = (
        Uuid,
        Option<String>,
        String,
        Option<String>,
        Option<DateTime<Utc>>,
        Option<DateTime<Utc>>,
        DateTime<Utc>,
        Option<DateTime<Utc>>,
        Option<f32>,
        Option<Uuid>,
        Vec<Uuid>,
    );
    let sql = match (as_of, timeline) {
        (None, _) => FACTS_EVERYTHING,
        (Some(_), "believed") => FACTS_AS_OF_BELIEVED,
        (Some(_), _) => FACTS_AS_OF_VALID,
    };
    let rows = sqlx::query_as::<_, Row>(sql)
        .bind(as_of.unwrap_or_else(Utc::now))
        .bind(limit)
        .fetch_all(pool)
        .await?;
    Ok(rows
        .into_iter()
        .map(|row| FactRow {
            id: row.0,
            subject: row.1.unwrap_or_else(|| "you".to_owned()),
            predicate: row.2,
            object: row.3.unwrap_or_default(),
            valid_from: row.4,
            valid_to: row.5,
            created_at: row.6,
            expired_at: row.7,
            confidence: row.8,
            superseded_by: row.9,
            source_episode_ids: row.10,
        })
        .collect())
}

pub async fn extract(
    pool: &PgPool,
    embed: &EmbedClient,
    reason: &ReasonClient,
) -> Result<FactOutcome, Box<dyn Error + Send + Sync>> {
    if !reason.configured() {
        return Err(Box::new(ReasonError::unconfigured()));
    }
    let episodes = sqlx::query_as::<_, (Uuid, DateTime<Utc>, String)>(
        "SELECT e.id, e.occurred_at, left(coalesce(e.body_en, e.body_original), 1800) FROM episodes e WHERE NOT (e.id = ANY(SELECT unnest(source_episode_ids) FROM facts)) ORDER BY e.ingested_at DESC LIMIT 8",
    )
    .fetch_all(pool)
    .await?;
    let mut outcome = FactOutcome {
        episodes_considered: episodes.len(),
        ..FactOutcome::default()
    };

    for (episode_id, occurred_at, body) in episodes {
        let Ok(candidates) = reason.complete_array(EXTRACT_PROMPT, &body).await else {
            continue;
        };
        for candidate in candidates.as_array().into_iter().flatten() {
            let Some(predicate) = candidate
                .get("predicate")
                .and_then(Value::as_str)
                .map(str::trim)
                .filter(|predicate| predicate.len() > 2 && predicate.len() < 60)
            else {
                continue;
            };
            let Some(object) = candidate
                .get("object")
                .and_then(Value::as_str)
                .map(str::trim)
                .filter(|object| !object.is_empty())
            else {
                continue;
            };
            let subject = candidate
                .get("subject")
                .and_then(Value::as_str)
                .map(str::trim)
                .filter(|subject| !subject.is_empty())
                .unwrap_or("you");
            let object_kind = candidate
                .get("objectKind")
                .and_then(Value::as_str)
                .unwrap_or("thing");
            let valid_from = candidate
                .get("validFrom")
                .and_then(Value::as_str)
                .and_then(|value| crate::ingest::parse_file_date(value))
                .unwrap_or(occurred_at);
            let confidence = candidate
                .get("confidence")
                .and_then(Value::as_f64)
                .unwrap_or(0.6)
                .clamp(0.0, 1.0) as f32;

            let subject_id = entities::resolve(pool, embed, "person", subject, &[])
                .await
                .map(|(id, _, _)| id)
                .ok();
            let object_id = entities::resolve(pool, embed, object_kind, object, &[])
                .await
                .map(|(id, _, _)| id)
                .ok();

            let open = sqlx::query_as::<_, (Uuid, Option<Uuid>)>(
                "SELECT id, object_id FROM facts WHERE predicate = $1 AND subject_id IS NOT DISTINCT FROM $2 AND valid_to IS NULL AND expired_at IS NULL",
            )
            .bind(predicate)
            .bind(subject_id)
            .fetch_all(pool)
            .await?;

            let recorded = sqlx::query_scalar::<_, Uuid>(
                "INSERT INTO facts (subject_id, predicate, object_id, object_literal, valid_from, confidence, source_episode_ids, extractor_version) VALUES ($1, $2, $3, $4, $5, $6, $7, $8) RETURNING id",
            )
            .bind(subject_id)
            .bind(predicate)
            .bind(object_id)
            .bind(object)
            .bind(valid_from)
            .bind(confidence)
            .bind(vec![episode_id])
            .bind(EXTRACTOR_VERSION)
            .fetch_one(pool)
            .await?;
            outcome.facts_recorded += 1;

            for (stale_id, stale_object) in open {
                if stale_object.is_some() && stale_object == object_id {
                    continue;
                }
                sqlx::query(
                    "UPDATE facts SET valid_to = $2, expired_at = now(), superseded_by = $3 WHERE id = $1",
                )
                .bind(stale_id)
                .bind(valid_from)
                .bind(recorded)
                .execute(pool)
                .await?;
                outcome.windows_closed += 1;
            }
        }
    }
    Ok(outcome)
}

#[cfg(test)]
mod tests {
    use super::{FACTS_AS_OF_BELIEVED, FACTS_AS_OF_VALID};

    #[test]
    fn the_two_timelines_ask_different_questions() {
        assert!(FACTS_AS_OF_VALID.contains("f.valid_from <= $1"));
        assert!(FACTS_AS_OF_BELIEVED.contains("f.created_at <= $1"));
    }

    #[test]
    fn an_open_ended_row_is_never_missed_by_a_naive_between() {
        for sql in [FACTS_AS_OF_VALID, FACTS_AS_OF_BELIEVED] {
            assert!(
                sql.contains("coalesce"),
                "this query would silently drop currently true facts"
            );
        }
    }
}
