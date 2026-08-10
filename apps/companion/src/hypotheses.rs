use std::error::Error;

use chrono::{DateTime, Duration, Utc};
use serde::Serialize;
use serde_json::Value;
use sqlx::PgPool;
use uuid::Uuid;

use crate::embed::EmbedClient;
use crate::indexer::halfvec_literal;
use crate::reason::{ReasonClient, ReasonError, extract_json_array};

pub const ACTIVE_CAP: i64 = 30;
pub const FALSIFIABLE_WITHIN_DAYS: i64 = 90;

const GENERATE_PROMPT: &str = "You form theories about one person and you expect to be wrong \
sometimes. A theory is not a summary: it names a mechanism, it could be false, and it predicts \
something you could check later against records of what they actually did. Answer with a JSON \
array only. Each item: {\"statement\": the theory, \"mechanism\": why it would work, one \
sentence, \"alternatives\": [at least two other explanations of the same evidence], \
\"prior\": number 0..1, \"prediction\": {\"statement\": what you expect to happen, \
\"observable\": exactly what record would confirm or deny it, \"days\": integer 3..60}}. One to \
three theories. A theory whose only support is what they said about themselves does not count, \
skip it. If the material carries nothing testable, answer [].";

const RESOLVE_PROMPT: &str = "You resolve one prediction against the record. Answer with a JSON \
array containing exactly one item: {\"outcome\": \"confirmed\"|\"denied\"|\"unresolvable\", \
\"note\": one sentence naming the record you used or the gap that stopped you}. Absence of \
records is unresolvable, not denied.";

#[derive(Debug, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct HypothesisOutcome {
    pub formed: usize,
    pub predictions_made: usize,
    pub skipped_at_cap: bool,
}

#[derive(Debug, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ResolveOutcome {
    pub resolved: usize,
    pub confirmed: usize,
    pub denied: usize,
    pub unresolvable: usize,
    pub retired: usize,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct HypothesisRow {
    pub id: Uuid,
    pub statement: String,
    pub mechanism: String,
    pub status: String,
    pub prior: f32,
    pub posterior: f32,
    pub test_count: i32,
    pub alternative_explanations: Vec<String>,
    pub formed_at: DateTime<Utc>,
    pub last_tested_at: Option<DateTime<Utc>>,
    pub generated_by: String,
}

pub fn next_posterior(posterior: f32, confirmed: bool) -> f32 {
    let odds = (posterior.clamp(0.02, 0.98) / (1.0 - posterior.clamp(0.02, 0.98))) as f64;
    let likelihood = if confirmed { 3.0 } else { 1.0 / 3.0 };
    let updated = odds * likelihood;
    ((updated / (1.0 + updated)) as f32).clamp(0.02, 0.98)
}

pub fn status_for(posterior: f32, tests: i32) -> &'static str {
    match posterior {
        value if value >= 0.8 && tests >= 2 => "supported",
        value if value <= 0.2 => "refuted",
        value if value < 0.4 => "weakened",
        _ if tests > 0 => "testing",
        _ => "proposed",
    }
}

pub async fn list(pool: &PgPool, limit: i64) -> Result<Vec<HypothesisRow>, sqlx::Error> {
    type Row = (
        Uuid,
        String,
        String,
        String,
        f32,
        f32,
        i32,
        Vec<String>,
        DateTime<Utc>,
        Option<DateTime<Utc>>,
        String,
    );
    let rows = sqlx::query_as::<_, Row>(
        "SELECT id, statement, mechanism, status, prior, posterior, test_count, alternative_explanations, formed_at, last_tested_at, generated_by FROM hypotheses ORDER BY (status = 'refuted'), formed_at DESC LIMIT $1",
    )
    .bind(limit)
    .fetch_all(pool)
    .await?;
    Ok(rows
        .into_iter()
        .map(|row| HypothesisRow {
            id: row.0,
            statement: row.1,
            mechanism: row.2,
            status: row.3,
            prior: row.4,
            posterior: row.5,
            test_count: row.6,
            alternative_explanations: row.7,
            formed_at: row.8,
            last_tested_at: row.9,
            generated_by: row.10,
        })
        .collect())
}

pub async fn generate(
    pool: &PgPool,
    embed: &EmbedClient,
    reason: &ReasonClient,
) -> Result<HypothesisOutcome, Box<dyn Error + Send + Sync>> {
    if !reason.configured() {
        return Err(Box::new(ReasonError::unconfigured()));
    }
    let active = sqlx::query_scalar::<_, i64>(
        "SELECT count(*) FROM hypotheses WHERE status IN ('proposed', 'testing')",
    )
    .fetch_one(pool)
    .await?;
    if active >= ACTIVE_CAP {
        return Ok(HypothesisOutcome {
            skipped_at_cap: true,
            ..HypothesisOutcome::default()
        });
    }

    let beliefs = sqlx::query_as::<_, (String, String, f32)>(
        "SELECT statement, corroboration, confidence FROM beliefs WHERE status = 'active' ORDER BY stability DESC, confidence DESC LIMIT 20",
    )
    .fetch_all(pool)
    .await?;
    type ObservationRow = (DateTime<Utc>, String, String, Value);
    let observations = sqlx::query_as::<_, ObservationRow>(
        "SELECT observed_at, source, kind, payload FROM observations ORDER BY observed_at DESC LIMIT 60",
    )
    .fetch_all(pool)
    .await?;
    let discrepancies = sqlx::query_as::<_, (String, String)>(
        "SELECT d.kind, c.statement FROM discrepancies d JOIN claims c ON c.id = d.claim_id WHERE NOT d.dismissed ORDER BY d.detected_at DESC LIMIT 15",
    )
    .fetch_all(pool)
    .await?;

    let mut outcome = HypothesisOutcome::default();
    if beliefs.is_empty() || observations.is_empty() {
        return Ok(outcome);
    }

    let existing = sqlx::query_scalar::<_, String>(
        "SELECT statement FROM hypotheses WHERE status IN ('proposed', 'testing', 'supported') ORDER BY formed_at DESC LIMIT 30",
    )
    .fetch_all(pool)
    .await?;

    let material = format!(
        "What the system believes:\n{}\n\nWhat independent records show:\n{}\n\nWhere their account and the record diverged:\n{}\n\nTheories it already holds, do not repeat these:\n{}",
        beliefs
            .iter()
            .map(|(statement, corroboration, confidence)| format!(
                "- ({corroboration}, {confidence:.2}) {statement}"
            ))
            .collect::<Vec<_>>()
            .join("\n"),
        observations
            .iter()
            .map(|(observed_at, source, kind, payload)| format!(
                "- {} {source} {kind} {payload}",
                observed_at.format("%Y-%m-%d %H:%M")
            ))
            .collect::<Vec<_>>()
            .join("\n"),
        if discrepancies.is_empty() {
            "- none recorded".to_owned()
        } else {
            discrepancies
                .iter()
                .map(|(kind, statement)| format!("- {kind}: {statement}"))
                .collect::<Vec<_>>()
                .join("\n")
        },
        if existing.is_empty() {
            "- none".to_owned()
        } else {
            existing
                .iter()
                .map(|statement| format!("- {statement}"))
                .collect::<Vec<_>>()
                .join("\n")
        },
    );

    let candidates = reason.complete_array(GENERATE_PROMPT, &material).await?;

    for candidate in candidates.as_array().into_iter().flatten() {
        let Some(statement) = candidate
            .get("statement")
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|statement| statement.len() > 15)
        else {
            continue;
        };
        let Some(mechanism) = candidate
            .get("mechanism")
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|mechanism| mechanism.len() > 10)
        else {
            continue;
        };
        let alternatives = candidate
            .get("alternatives")
            .and_then(Value::as_array)
            .map(|values| {
                values
                    .iter()
                    .filter_map(Value::as_str)
                    .map(str::trim)
                    .filter(|value| value.len() > 5)
                    .map(str::to_owned)
                    .collect::<Vec<_>>()
            })
            .unwrap_or_default();
        if alternatives.len() < 2 {
            continue;
        }
        let Some(prediction) = candidate.get("prediction") else {
            continue;
        };
        let Some(prediction_statement) = prediction
            .get("statement")
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|value| value.len() > 10)
        else {
            continue;
        };
        let Some(observable) = prediction
            .get("observable")
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|value| value.len() > 5)
        else {
            continue;
        };
        let days = prediction
            .get("days")
            .and_then(Value::as_i64)
            .unwrap_or(21)
            .clamp(3, FALSIFIABLE_WITHIN_DAYS);
        let prior = candidate
            .get("prior")
            .and_then(Value::as_f64)
            .unwrap_or(0.5)
            .clamp(0.05, 0.95) as f32;

        let embedding = halfvec_literal(&embed.embed(&[statement.to_owned()]).await?.remove(0));
        let duplicate = sqlx::query_scalar::<_, f64>(
            "SELECT 1 - (embedding <=> $1::halfvec) FROM hypotheses WHERE embedding IS NOT NULL ORDER BY embedding <=> $1::halfvec LIMIT 1",
        )
        .bind(&embedding)
        .fetch_optional(pool)
        .await?;
        if duplicate.is_some_and(|similarity| similarity >= 0.9) {
            continue;
        }

        let hypothesis_id = sqlx::query_scalar::<_, Uuid>(
            "INSERT INTO hypotheses (statement, mechanism, prior, posterior, alternative_explanations, embedding) VALUES ($1, $2, $3, $3, $4, $5::halfvec) RETURNING id",
        )
        .bind(statement)
        .bind(mechanism)
        .bind(prior)
        .bind(&alternatives)
        .bind(&embedding)
        .fetch_one(pool)
        .await?;
        let now = Utc::now();
        sqlx::query(
            "INSERT INTO predictions (hypothesis_id, statement, window_start, window_end, observable) VALUES ($1, $2, $3, $4, $5)",
        )
        .bind(hypothesis_id)
        .bind(prediction_statement)
        .bind(now)
        .bind(now + Duration::days(days))
        .bind(observable)
        .execute(pool)
        .await?;
        sqlx::query(
            "INSERT INTO hypothesis_revisions (hypothesis_id, posterior, status, note) VALUES ($1, $2, 'proposed', 'formed')",
        )
        .bind(hypothesis_id)
        .bind(prior)
        .execute(pool)
        .await?;
        outcome.formed += 1;
        outcome.predictions_made += 1;
    }
    Ok(outcome)
}

pub async fn resolve_due(
    pool: &PgPool,
    reason: &ReasonClient,
) -> Result<ResolveOutcome, Box<dyn Error + Send + Sync>> {
    if !reason.configured() {
        return Err(Box::new(ReasonError::unconfigured()));
    }
    let mut outcome = ResolveOutcome::default();
    type Row = (Uuid, Uuid, String, String, DateTime<Utc>, DateTime<Utc>, f32, i32);
    let due = sqlx::query_as::<_, Row>(
        "SELECT p.id, p.hypothesis_id, p.statement, p.observable, p.window_start, p.window_end, h.posterior, h.test_count FROM predictions p JOIN hypotheses h ON h.id = p.hypothesis_id WHERE p.resolved_at IS NULL AND p.window_end <= now() ORDER BY p.window_end LIMIT 10",
    )
    .fetch_all(pool)
    .await?;

    for (prediction_id, hypothesis_id, statement, observable, start, end, posterior, tests) in due {
        type ObservationRow = (DateTime<Utc>, String, String, Value);
        let observations = sqlx::query_as::<_, ObservationRow>(
            "SELECT observed_at, source, kind, payload FROM observations WHERE observed_at BETWEEN $1 AND $2 ORDER BY observed_at LIMIT 80",
        )
        .bind(start)
        .bind(end)
        .fetch_all(pool)
        .await?;
        let records = if observations.is_empty() {
            "no records in the window".to_owned()
        } else {
            observations
                .iter()
                .map(|(observed_at, source, kind, payload)| {
                    format!(
                        "{} {source} {kind} {payload}",
                        observed_at.format("%Y-%m-%d %H:%M")
                    )
                })
                .collect::<Vec<_>>()
                .join("\n")
        };
        let prompt = format!(
            "Prediction: {statement}\nWhat would confirm or deny it: {observable}\nWindow: {} to {}\n\nRecords:\n{records}",
            start.format("%Y-%m-%d"),
            end.format("%Y-%m-%d")
        );
        let answer = reason.complete(RESOLVE_PROMPT, &prompt).await?;
        let parsed = extract_json_array(&answer)
            .and_then(|array| array.as_array().and_then(|items| items.first().cloned()));
        let (verdict, note) = match parsed {
            Some(item) => (
                item.get("outcome")
                    .and_then(Value::as_str)
                    .filter(|outcome| {
                        ["confirmed", "denied", "unresolvable"].contains(outcome)
                    })
                    .unwrap_or("unresolvable")
                    .to_owned(),
                item.get("note")
                    .and_then(Value::as_str)
                    .unwrap_or("no note")
                    .trim()
                    .to_owned(),
            ),
            None => (
                "unresolvable".to_owned(),
                "resolver answer was unparseable".to_owned(),
            ),
        };

        sqlx::query("UPDATE predictions SET resolved_at = now(), outcome = $2 WHERE id = $1")
            .bind(prediction_id)
            .bind(&verdict)
            .execute(pool)
            .await?;
        outcome.resolved += 1;

        match verdict.as_str() {
            "confirmed" | "denied" => {
                let confirmed = verdict == "confirmed";
                let updated = next_posterior(posterior, confirmed);
                let tests = tests + 1;
                let status = status_for(updated, tests);
                sqlx::query(
                    "UPDATE hypotheses SET posterior = $2, status = $3, test_count = $4, last_tested_at = now(), supporting_ids = CASE WHEN $5 THEN array_append(supporting_ids, $6) ELSE supporting_ids END, refuting_ids = CASE WHEN $5 THEN refuting_ids ELSE array_append(refuting_ids, $6) END WHERE id = $1",
                )
                .bind(hypothesis_id)
                .bind(updated)
                .bind(status)
                .bind(tests)
                .bind(confirmed)
                .bind(prediction_id)
                .execute(pool)
                .await?;
                sqlx::query(
                    "INSERT INTO hypothesis_revisions (hypothesis_id, posterior, status, trigger_prediction_id, note) VALUES ($1, $2, $3, $4, $5)",
                )
                .bind(hypothesis_id)
                .bind(updated)
                .bind(status)
                .bind(prediction_id)
                .bind(&note)
                .execute(pool)
                .await?;
                if confirmed {
                    outcome.confirmed += 1;
                } else {
                    outcome.denied += 1;
                }
            }
            _ => {
                outcome.unresolvable += 1;
                sqlx::query(
                    "INSERT INTO hypothesis_revisions (hypothesis_id, posterior, status, trigger_prediction_id, note) VALUES ($1, $2, 'testing', $3, $4)",
                )
                .bind(hypothesis_id)
                .bind(posterior)
                .bind(prediction_id)
                .bind(&note)
                .execute(pool)
                .await?;
            }
        }
    }

    outcome.retired = retire_untestable(pool).await? as usize;
    Ok(outcome)
}

pub async fn retire_untestable(pool: &PgPool) -> Result<u64, sqlx::Error> {
    let cutoff = Utc::now() - Duration::days(FALSIFIABLE_WITHIN_DAYS);
    let retired = sqlx::query(
        "UPDATE hypotheses SET status = 'retired' WHERE status IN ('proposed', 'testing') AND formed_at < $1 AND NOT EXISTS (SELECT 1 FROM predictions p WHERE p.hypothesis_id = hypotheses.id AND p.resolved_at IS NOT NULL)",
    )
    .bind(cutoff)
    .execute(pool)
    .await?;
    Ok(retired.rows_affected())
}

#[cfg(test)]
mod tests {
    use super::{next_posterior, status_for};

    #[test]
    fn confirmation_raises_and_denial_lowers() {
        assert!(next_posterior(0.5, true) > 0.5);
        assert!(next_posterior(0.5, false) < 0.5);
    }

    #[test]
    fn a_posterior_never_reaches_certainty() {
        let mut value = 0.5;
        for _ in 0..40 {
            value = next_posterior(value, true);
        }
        assert!(value < 1.0);
        assert!(value >= 0.9);
    }

    #[test]
    fn repeated_denial_refutes() {
        let mut value = 0.5;
        let mut tests = 0;
        for _ in 0..4 {
            value = next_posterior(value, false);
            tests += 1;
        }
        assert_eq!(status_for(value, tests), "refuted");
    }

    #[test]
    fn an_untested_theory_is_only_proposed() {
        assert_eq!(status_for(0.5, 0), "proposed");
        assert_eq!(status_for(0.9, 1), "testing");
        assert_eq!(status_for(0.9, 2), "supported");
    }
}
