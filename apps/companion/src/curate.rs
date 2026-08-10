use std::error::Error;

use serde::Serialize;
use serde_json::Value;
use sqlx::PgPool;
use uuid::Uuid;

use crate::embed::EmbedClient;
use crate::indexer::halfvec_literal;
use crate::reason::{ReasonClient, ReasonError};

pub const RELATIONS: [&str; 3] = ["supports", "tensions_with", "refines"];

const LINK_PROMPT: &str = "You relate one belief about a person to others held about them. Answer \
with a JSON array only. Each item: {\"id\": the id of the other belief, \"relation\": \
supports|tensions_with|refines}. supports means both can be true and one strengthens the other, \
tensions_with means they pull against each other without either being settled, refines means the \
first is a sharper version of the second. Only relate beliefs that genuinely bear on each other, \
and answer [] when none do.";

#[derive(Debug, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CurateOutcome {
    pub beliefs_examined: usize,
    pub links_made: usize,
    pub contested_reopened: usize,
    pub retired: usize,
}

#[derive(Debug, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RebuildOutcome {
    pub chunks_dropped: u64,
    pub beliefs_retired: u64,
    pub facts_expired: u64,
    pub episodes_kept: i64,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CorrectOutcome {
    pub id: Uuid,
    pub status: String,
    pub statement: String,
}

pub async fn correct(
    pool: &PgPool,
    embed: &EmbedClient,
    id: Uuid,
    retire: bool,
    edit: Option<&str>,
) -> Result<CorrectOutcome, Box<dyn Error + Send + Sync>> {
    let Some(existing) =
        sqlx::query_scalar::<_, String>("SELECT statement FROM beliefs WHERE id = $1")
            .bind(id)
            .fetch_optional(pool)
            .await?
    else {
        return Err("no such belief".into());
    };

    if let Some(statement) = edit.map(str::trim).filter(|statement| statement.len() > 5) {
        let embedding = halfvec_literal(&embed.embed(&[statement.to_owned()]).await?.remove(0));
        let replacement = sqlx::query_scalar::<_, Uuid>(
            "INSERT INTO beliefs (statement, kind, confidence, stability, corroboration, evidence_episode_ids, counter_evidence_episode_ids, extractor_version, embedding, status) SELECT $2, kind, confidence, stability, corroboration, evidence_episode_ids, counter_evidence_episode_ids, 'user-edit', $3::halfvec, 'active' FROM beliefs WHERE id = $1 RETURNING id",
        )
        .bind(id)
        .bind(statement)
        .bind(&embedding)
        .fetch_one(pool)
        .await?;
        sqlx::query("UPDATE beliefs SET status = 'superseded', superseded_by = $2 WHERE id = $1")
            .bind(id)
            .bind(replacement)
            .execute(pool)
            .await?;
        return Ok(CorrectOutcome {
            id: replacement,
            status: "active".to_owned(),
            statement: statement.to_owned(),
        });
    }

    if retire {
        sqlx::query("UPDATE beliefs SET status = 'retired' WHERE id = $1")
            .bind(id)
            .execute(pool)
            .await?;
        return Ok(CorrectOutcome {
            id,
            status: "retired".to_owned(),
            statement: existing,
        });
    }

    Err("pass --retire or --edit".into())
}

pub async fn weekly(
    pool: &PgPool,
    embed: &EmbedClient,
    reason: &ReasonClient,
) -> Result<CurateOutcome, Box<dyn Error + Send + Sync>> {
    if !reason.configured() {
        return Err(Box::new(ReasonError::unconfigured()));
    }
    let mut outcome = CurateOutcome::default();

    let beliefs = sqlx::query_as::<_, (Uuid, String, String)>(
        "SELECT id, statement, status FROM beliefs WHERE status IN ('active', 'contested') ORDER BY last_confirmed DESC LIMIT 40",
    )
    .fetch_all(pool)
    .await?;
    outcome.beliefs_examined = beliefs.len();
    if beliefs.len() < 2 {
        return Ok(outcome);
    }

    for (id, statement, _) in &beliefs {
        let others = beliefs
            .iter()
            .filter(|(other, _, _)| other != id)
            .map(|(other, other_statement, _)| format!("{other}: {other_statement}"))
            .collect::<Vec<_>>()
            .join("\n");
        let prompt = format!("The belief: {statement}\n\nThe others:\n{others}");
        let Ok(candidates) = reason.complete_array(LINK_PROMPT, &prompt).await else {
            continue;
        };
        for candidate in candidates.as_array().into_iter().flatten() {
            let Some(target) = candidate
                .get("id")
                .and_then(Value::as_str)
                .and_then(|value| Uuid::parse_str(value).ok())
                .filter(|target| target != id)
                .filter(|target| beliefs.iter().any(|(known, _, _)| known == target))
            else {
                continue;
            };
            let Some(relation) = candidate
                .get("relation")
                .and_then(Value::as_str)
                .filter(|relation| RELATIONS.contains(relation))
            else {
                continue;
            };
            let inserted = sqlx::query(
                "INSERT INTO belief_links (from_id, to_id, relation) VALUES ($1, $2, $3) ON CONFLICT DO NOTHING",
            )
            .bind(id)
            .bind(target)
            .bind(relation)
            .execute(pool)
            .await?;
            outcome.links_made += inserted.rows_affected() as usize;
            if relation == "tensions_with" {
                let contested = sqlx::query(
                    "UPDATE beliefs SET status = 'contested' WHERE id = ANY($1) AND status = 'active'",
                )
                .bind(vec![*id, target])
                .execute(pool)
                .await?;
                outcome.contested_reopened += contested.rows_affected() as usize;
            }
        }
    }

    let retired = sqlx::query(
        "UPDATE beliefs SET status = 'retired' WHERE status = 'active' AND first_formed < now() - interval '30 days' AND NOT EXISTS (SELECT 1 FROM retrievals r WHERE r.item_type = 'belief' AND r.chunk_id = beliefs.id)",
    )
    .execute(pool)
    .await?;
    outcome.retired = retired.rows_affected() as usize;

    let _ = embed;
    Ok(outcome)
}

pub async fn rebuild_derived(pool: &PgPool) -> Result<RebuildOutcome, sqlx::Error> {
    let episodes = sqlx::query_scalar::<_, i64>("SELECT count(*) FROM episodes")
        .fetch_one(pool)
        .await?;
    let chunks = sqlx::query("DELETE FROM chunks").execute(pool).await?;
    let beliefs = sqlx::query(
        "UPDATE beliefs SET status = 'retired' WHERE status IN ('active', 'contested', 'superseded')",
    )
    .execute(pool)
    .await?;
    let facts = sqlx::query("UPDATE facts SET expired_at = now() WHERE expired_at IS NULL")
        .execute(pool)
        .await?;
    Ok(RebuildOutcome {
        chunks_dropped: chunks.rows_affected(),
        beliefs_retired: beliefs.rows_affected(),
        facts_expired: facts.rows_affected(),
        episodes_kept: episodes,
    })
}

pub async fn reindex(pool: &PgPool) -> Result<u64, sqlx::Error> {
    let dropped = sqlx::query("DELETE FROM chunks").execute(pool).await?;
    Ok(dropped.rows_affected())
}

#[cfg(test)]
mod tests {
    use super::RELATIONS;

    #[test]
    fn a_tension_is_a_first_class_relation() {
        assert!(RELATIONS.contains(&"tensions_with"));
        assert!(RELATIONS.contains(&"refines"));
        assert!(RELATIONS.contains(&"supports"));
    }
}
