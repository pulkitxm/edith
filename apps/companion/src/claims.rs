use std::error::Error;

use chrono::{DateTime, Duration, Utc};
use serde::Serialize;
use serde_json::Value;
use sqlx::PgPool;
use uuid::Uuid;

use crate::ask::extract_json_object;
use crate::reason::{ReasonClient, extract_json_array};

const CLAIM_TYPES: [&str; 8] = [
    "fact",
    "intention",
    "commitment",
    "progress",
    "self_assessment",
    "prediction",
    "preference",
    "feeling",
];

const EXTRACT_PROMPT: &str = "You extract the claims a person makes in their own words. A claim \
is one assertion they committed to: something done, planned, felt or believed. Answer with a \
JSON array only. Each item: {\"statement\": string in their words, \"claimType\": one of fact, \
intention, commitment, progress, self_assessment, prediction, preference, feeling, \
\"testable\": bool, true when independent records like commits or calendars could confirm it}. \
Zero to six claims. No commentary.";

const JUDGE_PROMPT: &str = "You compare one claim a person made against their recorded activity. \
Answer with a JSON array containing exactly one item: {\"verdict\": \"corroborated\" when the \
records support the claim, \"contradicted\" when they conflict with it, \"unclear\" when the \
records neither support nor deny it, \"note\": one sentence naming the record or the gap}. \
Judge only from the records given; absence of records means unclear, not contradicted.";

#[derive(Debug, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ExtractOutcome {
    pub episodes_considered: usize,
    pub claims_extracted: usize,
}

#[derive(Debug, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CorroborateOutcome {
    pub claims_checked: usize,
    pub corroborated: usize,
    pub contradicted: usize,
    pub unclear: usize,
}

pub async fn extract_claims(
    pool: &PgPool,
    reason: &ReasonClient,
) -> Result<ExtractOutcome, Box<dyn Error + Send + Sync>> {
    let episodes = sqlx::query_as::<_, (Uuid, DateTime<Utc>, String)>(
        "SELECT e.id, e.occurred_at, left(e.body_original, 1500) FROM episodes e WHERE NOT EXISTS (SELECT 1 FROM claims c WHERE c.episode_id = e.id) ORDER BY e.ingested_at DESC LIMIT 10",
    )
    .fetch_all(pool)
    .await?;
    let mut outcome = ExtractOutcome {
        episodes_considered: episodes.len(),
        claims_extracted: 0,
    };

    for (episode_id, occurred_at, body) in episodes {
        let Ok(candidates) = reason.complete_array(EXTRACT_PROMPT, &body).await else {
            continue;
        };
        for candidate in candidates.as_array().into_iter().flatten() {
            let Some(statement) = candidate
                .get("statement")
                .and_then(Value::as_str)
                .map(str::trim)
                .filter(|statement| statement.len() > 5)
            else {
                continue;
            };
            let Some(claim_type) = candidate
                .get("claimType")
                .and_then(Value::as_str)
                .filter(|kind| CLAIM_TYPES.contains(kind))
            else {
                continue;
            };
            let testable = candidate
                .get("testable")
                .and_then(Value::as_bool)
                .unwrap_or(false);
            sqlx::query(
                "INSERT INTO claims (episode_id, statement, asserted_at, claim_type, testable) VALUES ($1, $2, $3, $4, $5)",
            )
            .bind(episode_id)
            .bind(statement)
            .bind(occurred_at)
            .bind(claim_type)
            .bind(testable)
            .execute(pool)
            .await?;
            outcome.claims_extracted += 1;
        }
    }
    Ok(outcome)
}

pub async fn corroborate_claims(
    pool: &PgPool,
    reason: &ReasonClient,
) -> Result<CorroborateOutcome, Box<dyn Error + Send + Sync>> {
    let claims = sqlx::query_as::<_, (Uuid, String, DateTime<Utc>)>(
        "SELECT c.id, c.statement, c.asserted_at FROM claims c WHERE c.testable AND c.claim_type IN ('progress', 'commitment', 'fact') AND NOT EXISTS (SELECT 1 FROM corroborations x WHERE x.claim_id = c.id) ORDER BY c.asserted_at DESC LIMIT 10",
    )
    .fetch_all(pool)
    .await?;
    let mut outcome = CorroborateOutcome::default();

    for (claim_id, statement, asserted_at) in claims {
        let window_start = asserted_at - Duration::hours(96);
        let window_end = asserted_at + Duration::hours(96);
        type ObservationRow = (Uuid, DateTime<Utc>, String, Value);
        let observations = sqlx::query_as::<_, ObservationRow>(
            "SELECT id, observed_at, kind, payload FROM observations WHERE observed_at BETWEEN $1 AND $2 ORDER BY observed_at LIMIT 40",
        )
        .bind(window_start)
        .bind(window_end)
        .fetch_all(pool)
        .await?;

        let records = if observations.is_empty() {
            "no records in the window".to_owned()
        } else {
            observations
                .iter()
                .map(|(_, observed_at, kind, payload)| {
                    format!("{} {kind} {payload}", observed_at.format("%Y-%m-%d %H:%M"))
                })
                .collect::<Vec<_>>()
                .join("\n")
        };
        let prompt = format!(
            "Claim, asserted {}: {statement}\n\nRecords within four days:\n{records}",
            asserted_at.format("%Y-%m-%d")
        );
        let answer = reason.complete(JUDGE_PROMPT, &prompt).await?;
        let judgement = extract_json_array(&answer)
            .and_then(|array| array.as_array().and_then(|items| items.first().cloned()))
            .or_else(|| extract_json_object(&answer));
        let (verdict, note) = match judgement {
            Some(item) => {
                let verdict = item
                    .get("verdict")
                    .and_then(Value::as_str)
                    .filter(|verdict| ["corroborated", "contradicted", "unclear"].contains(verdict))
                    .unwrap_or("unclear")
                    .to_owned();
                let note = item
                    .get("note")
                    .and_then(Value::as_str)
                    .unwrap_or("no note")
                    .trim()
                    .to_owned();
                (verdict, note)
            }
            None => (
                "unclear".to_owned(),
                "judge answer was unparseable".to_owned(),
            ),
        };

        let observation_ids = observations.iter().map(|row| row.0).collect::<Vec<_>>();
        sqlx::query(
            "INSERT INTO corroborations (claim_id, verdict, note, observation_ids) VALUES ($1, $2, $3, $4)",
        )
        .bind(claim_id)
        .bind(&verdict)
        .bind(&note)
        .bind(&observation_ids)
        .execute(pool)
        .await?;
        outcome.claims_checked += 1;
        match verdict.as_str() {
            "corroborated" => outcome.corroborated += 1,
            "contradicted" => outcome.contradicted += 1,
            _ => outcome.unclear += 1,
        }
    }
    Ok(outcome)
}
