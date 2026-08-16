use std::error::Error;

use chrono::{DateTime, Utc};
use serde::Serialize;
use serde_json::Value;
use sqlx::PgPool;
use uuid::Uuid;

use crate::embed::EmbedClient;
use crate::indexer::halfvec_literal;
use crate::reason::{ReasonClient, ReasonError};

const KINDS: [&str; 5] = ["person", "project", "place", "organisation", "thing"];

const EXTRACT_PROMPT: &str = "You pull the named things out of one person's own writing: people, \
projects, places, organisations. Answer with a JSON array only. Each item: {\"name\": the \
canonical form you would file it under, \"kind\": person|project|place|organisation|thing, \
\"surfaces\": [every spelling that appears in this text, including Devanagari, romanised and \
misspelled forms]}. Devanagari and romanised forms of one name are one entity, never two. Skip \
generic words and anything that is not actually named. Zero to eight items.";

#[derive(Debug, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct EntityOutcome {
    pub episodes_considered: usize,
    pub entities_created: usize,
    pub aliases_added: usize,
    pub mentions_linked: usize,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct EntityRow {
    pub id: Uuid,
    pub kind: String,
    pub canonical_name: String,
    pub aliases: Vec<String>,
    pub mention_count: i32,
    pub first_seen: DateTime<Utc>,
    pub last_seen: DateTime<Utc>,
}

pub fn script_of(text: &str) -> &'static str {
    let deva = text.chars().any(|character| {
        ('\u{0900}'..='\u{097F}').contains(&character)
    });
    let latin = text
        .chars()
        .any(|character| character.is_ascii_alphabetic());
    match (deva, latin) {
        (true, true) => "mixed",
        (true, false) => "deva",
        _ => "latn",
    }
}

pub fn normalize(value: &str) -> String {
    value
        .trim()
        .trim_matches(|character: char| !character.is_alphanumeric())
        .to_lowercase()
}

pub async fn list(pool: &PgPool, limit: i64) -> Result<Vec<EntityRow>, sqlx::Error> {
    type Row = (
        Uuid,
        String,
        String,
        Vec<String>,
        i32,
        DateTime<Utc>,
        DateTime<Utc>,
    );
    let rows = sqlx::query_as::<_, Row>(
        "SELECT id, kind, canonical_name, aliases, mention_count, first_seen, last_seen FROM entities ORDER BY mention_count DESC, last_seen DESC LIMIT $1",
    )
    .bind(limit)
    .fetch_all(pool)
    .await?;
    Ok(rows
        .into_iter()
        .map(|row| EntityRow {
            id: row.0,
            kind: row.1,
            canonical_name: row.2,
            aliases: row.3,
            mention_count: row.4,
            first_seen: row.5,
            last_seen: row.6,
        })
        .collect())
}

pub async fn resolve(
    pool: &PgPool,
    embed: &EmbedClient,
    kind: &str,
    name: &str,
    surfaces: &[String],
) -> Result<(Uuid, bool, usize), Box<dyn Error + Send + Sync>> {
    let mut forms = surfaces
        .iter()
        .map(|surface| surface.trim().to_owned())
        .filter(|surface| !surface.is_empty())
        .collect::<Vec<_>>();
    if !forms.iter().any(|form| normalize(form) == normalize(name)) {
        forms.push(name.to_owned());
    }
    let lowered = forms.iter().map(|form| normalize(form)).collect::<Vec<_>>();

    let existing = sqlx::query_scalar::<_, Uuid>(
        "SELECT id FROM entities WHERE kind = $1 AND (lower(canonical_name) = ANY($2) OR EXISTS (SELECT 1 FROM unnest(aliases) alias WHERE lower(alias) = ANY($2))) LIMIT 1",
    )
    .bind(kind)
    .bind(&lowered)
    .fetch_optional(pool)
    .await?;

    let embedding = halfvec_literal(&embed.embed(&[name.to_owned()]).await?.remove(0));
    let entity_id = match existing {
        Some(id) => id,
        None => {
            let nearest = sqlx::query_as::<_, (Uuid, f64)>(
                "SELECT id, 1 - (embedding <=> $2::halfvec) FROM entities WHERE kind = $1 AND embedding IS NOT NULL ORDER BY embedding <=> $2::halfvec LIMIT 1",
            )
            .bind(kind)
            .bind(&embedding)
            .fetch_optional(pool)
            .await?;
            match nearest {
                Some((id, similarity)) if similarity >= 0.94 => id,
                _ => {
                    let created = create(pool, kind, name, &forms, &embedding).await?;
                    return Ok((created, true, forms.len()));
                }
            }
        }
    };

    let added = sqlx::query(
        "UPDATE entities SET aliases = ARRAY(SELECT DISTINCT unnest(aliases || $2::text[])), last_seen = now() WHERE id = $1 AND NOT (aliases @> $2::text[])",
    )
    .bind(entity_id)
    .bind(&forms)
    .execute(pool)
    .await?;
    Ok((entity_id, false, added.rows_affected() as usize))
}

async fn create(
    pool: &PgPool,
    kind: &str,
    name: &str,
    forms: &[String],
    embedding: &str,
) -> Result<Uuid, sqlx::Error> {
    sqlx::query_scalar::<_, Uuid>(
        "INSERT INTO entities (kind, canonical_name, aliases, embedding) VALUES ($1, $2, $3, $4::halfvec) ON CONFLICT (kind, canonical_name) DO UPDATE SET aliases = ARRAY(SELECT DISTINCT unnest(entities.aliases || EXCLUDED.aliases)), last_seen = now() RETURNING id",
    )
    .bind(kind)
    .bind(name)
    .bind(forms)
    .bind(embedding)
    .fetch_one(pool)
    .await
}

pub async fn extract(
    pool: &PgPool,
    embed: &EmbedClient,
    reason: &ReasonClient,
) -> Result<EntityOutcome, Box<dyn Error + Send + Sync>> {
    if !reason.configured() {
        return Err(Box::new(ReasonError::unconfigured()));
    }
    let episodes = sqlx::query_as::<_, (Uuid, String)>(
        "SELECT e.id, left(coalesce(e.body_en, e.body_original), 2000) FROM episodes e WHERE NOT EXISTS (SELECT 1 FROM entity_mentions m WHERE m.episode_id = e.id) ORDER BY e.ingested_at DESC LIMIT 10",
    )
    .fetch_all(pool)
    .await?;
    let mut outcome = EntityOutcome {
        episodes_considered: episodes.len(),
        ..EntityOutcome::default()
    };

    for (episode_id, body) in episodes {
        let Ok(candidates) = reason.complete_array(EXTRACT_PROMPT, &body).await else {
            continue;
        };
        for candidate in candidates.as_array().into_iter().flatten() {
            let Some(name) = candidate
                .get("name")
                .and_then(Value::as_str)
                .map(str::trim)
                .filter(|name| name.len() > 1)
            else {
                continue;
            };
            let kind = candidate
                .get("kind")
                .and_then(Value::as_str)
                .filter(|kind| KINDS.contains(kind))
                .unwrap_or("thing");
            let surfaces = candidate
                .get("surfaces")
                .and_then(Value::as_array)
                .map(|values| {
                    values
                        .iter()
                        .filter_map(Value::as_str)
                        .map(str::trim)
                        .filter(|value| !value.is_empty())
                        .map(str::to_owned)
                        .collect::<Vec<_>>()
                })
                .unwrap_or_default();

            let (entity_id, created, aliases) =
                resolve(pool, embed, kind, name, &surfaces).await?;
            if created {
                outcome.entities_created += 1;
            }
            outcome.aliases_added += aliases;

            for surface in surfaces.iter().chain(std::iter::once(&name.to_owned())) {
                let linked = sqlx::query(
                    "INSERT INTO entity_mentions (entity_id, episode_id, surface, script) VALUES ($1, $2, $3, $4) ON CONFLICT (entity_id, episode_id, surface) DO NOTHING",
                )
                .bind(entity_id)
                .bind(episode_id)
                .bind(surface)
                .bind(script_of(surface))
                .execute(pool)
                .await?;
                outcome.mentions_linked += linked.rows_affected() as usize;
            }
            sqlx::query(
                "UPDATE entities SET mention_count = (SELECT count(DISTINCT episode_id) FROM entity_mentions WHERE entity_id = $1), last_seen = now() WHERE id = $1",
            )
            .bind(entity_id)
            .execute(pool)
            .await?;
        }
    }
    Ok(outcome)
}

pub async fn timeline(
    pool: &PgPool,
    name: &str,
    limit: i64,
) -> Result<Vec<Value>, sqlx::Error> {
    let rows = sqlx::query_as::<_, (Uuid, DateTime<Utc>, String, String, String)>(
        "SELECT DISTINCT e.id, e.occurred_at, e.kind, e.title, m.surface FROM entities en JOIN entity_mentions m ON m.entity_id = en.id JOIN episodes e ON e.id = m.episode_id WHERE lower(en.canonical_name) = lower($1) OR EXISTS (SELECT 1 FROM unnest(en.aliases) alias WHERE lower(alias) = lower($1)) ORDER BY e.occurred_at DESC LIMIT $2",
    )
    .bind(name)
    .bind(limit)
    .fetch_all(pool)
    .await?;
    Ok(rows
        .into_iter()
        .map(|(id, occurred_at, kind, title, surface)| {
            serde_json::json!({
                "episodeId": id,
                "occurredAt": occurred_at.to_rfc3339(),
                "kind": kind,
                "title": title,
                "surface": surface,
            })
        })
        .collect())
}

#[cfg(test)]
mod tests {
    use super::{normalize, script_of};

    #[test]
    fn scripts_are_detected_including_the_mixed_case() {
        assert_eq!(script_of("Warden"), "latn");
        assert_eq!(script_of("पुलकित"), "deva");
        assert_eq!(script_of("पुलकित Warden"), "mixed");
    }

    #[test]
    fn normalising_folds_case_and_punctuation() {
        assert_eq!(normalize(" Warden, "), "warden");
        assert_eq!(normalize("WARDEN"), normalize("warden"));
    }
}
