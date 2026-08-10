use std::error::Error;

use chrono::{DateTime, Duration, Utc};
use serde::Serialize;
use serde_json::{Value, json};
use sqlx::PgPool;
use uuid::Uuid;

use crate::reason::{ReasonClient, ReasonError, extract_json_array};

const OBSERVABLE_PROMPT: &str = "You turn one thing a person committed to into the record that \
would show whether it happened. Answer with a JSON array containing exactly one item: \
{\"observable\": {\"sources\": [\"github\"|\"calendar\"|\"music\"|\"youtube\"|\"edith\"], \
\"keywords\": [words that would appear in such a record], \"days\": integer 1..14}, \"dueDays\": \
integer 1..14}. Keywords are for matching records, keep them concrete: repository names, file \
paths, feature names.";

const RESOLVE_PROMPT: &str = "You decide whether one commitment was met, from records alone. \
Answer with a JSON array containing exactly one item: {\"status\": \"met\"|\"partial\"|\
\"missed\"|\"invalidated\", \"note\": one sentence naming the record or the gap}. Missed means \
the records cover the window and show nothing; invalidated means the records show the thing \
stopped being the right thing to do. Never guess at why. State what the records show and stop.";

const DISCREPANCY_PROMPT: &str = "You compare what a person said about their own work against \
the record of what they did. Answer with a JSON array containing exactly one item: {\"kind\": \
\"overstated\"|\"understated\"|\"timing_off\"|\"invisible_work\"|\"accurate\", \"magnitude\": \
number 0..1, \"note\": one sentence}. understated means the record is better than their account \
of it, and it matters as much as overstated. invisible_work means the work plausibly happened \
somewhere the records cannot see. Do not assign a motive.";

#[derive(Debug, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CommitmentOutcome {
    pub tracked: usize,
    pub resolved: usize,
    pub met: usize,
    pub partial: usize,
    pub missed: usize,
    pub invalidated: usize,
}

#[derive(Debug, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DiscrepancyOutcome {
    pub claims_checked: usize,
    pub discrepancies: usize,
    pub calibrations: usize,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CommitmentRow {
    pub id: Uuid,
    pub claim: String,
    pub stated_at: DateTime<Utc>,
    pub due_by: DateTime<Utc>,
    pub status: String,
    pub observable: Value,
    pub resolved_at: Option<DateTime<Utc>>,
    pub user_override: Option<String>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DiscrepancyRow {
    pub id: Uuid,
    pub claim: String,
    pub kind: String,
    pub magnitude: f32,
    pub detected_at: DateTime<Utc>,
    pub dismissed: bool,
    pub user_response: Option<String>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CalibrationSummary {
    pub domain: String,
    pub direction: String,
    pub samples: i64,
    pub average_magnitude: f32,
}

pub async fn track(
    pool: &PgPool,
    reason: &ReasonClient,
) -> Result<CommitmentOutcome, Box<dyn Error + Send + Sync>> {
    if !reason.configured() {
        return Err(Box::new(ReasonError::unconfigured()));
    }
    let mut outcome = CommitmentOutcome::default();

    let pending = sqlx::query_as::<_, (Uuid, String, DateTime<Utc>)>(
        "SELECT c.id, c.statement, c.asserted_at FROM claims c WHERE c.claim_type IN ('commitment', 'intention') AND NOT EXISTS (SELECT 1 FROM commitments m WHERE m.claim_id = c.id) ORDER BY c.asserted_at DESC LIMIT 10",
    )
    .fetch_all(pool)
    .await?;
    for (claim_id, statement, asserted_at) in pending {
        let answer = reason.complete(OBSERVABLE_PROMPT, &statement).await?;
        let parsed = extract_json_array(&answer)
            .and_then(|array| array.as_array().and_then(|items| items.first().cloned()));
        let (observable, due_days) = match parsed {
            Some(item) => (
                item.get("observable").cloned().unwrap_or(json!({})),
                item.get("dueDays").and_then(Value::as_i64).unwrap_or(1),
            ),
            None => (json!({}), 1),
        };
        sqlx::query(
            "INSERT INTO commitments (claim_id, stated_at, due_by, observable) VALUES ($1, $2, $3, $4) ON CONFLICT (claim_id) DO NOTHING",
        )
        .bind(claim_id)
        .bind(asserted_at)
        .bind(asserted_at + Duration::days(due_days.clamp(1, 14)))
        .bind(&observable)
        .execute(pool)
        .await?;
        outcome.tracked += 1;
    }

    type DueRow = (Uuid, Uuid, String, DateTime<Utc>, DateTime<Utc>, Value);
    let due = sqlx::query_as::<_, DueRow>(
        "SELECT m.id, m.claim_id, c.statement, m.stated_at, m.due_by, m.observable FROM commitments m JOIN claims c ON c.id = m.claim_id WHERE m.status = 'open' AND m.due_by <= now() ORDER BY m.due_by LIMIT 10",
    )
    .fetch_all(pool)
    .await?;
    for (commitment_id, _claim_id, statement, stated_at, due_by, observable) in due {
        let observations = window_observations(pool, stated_at, due_by + Duration::days(1)).await?;
        let prompt = format!(
            "Commitment stated {}: {statement}\nWhat would show it happened: {observable}\n\nRecords up to {}:\n{}",
            stated_at.format("%Y-%m-%d"),
            due_by.format("%Y-%m-%d"),
            render_observations(&observations)
        );
        let answer = reason.complete(RESOLVE_PROMPT, &prompt).await?;
        let parsed = extract_json_array(&answer)
            .and_then(|array| array.as_array().and_then(|items| items.first().cloned()));
        let status = parsed
            .as_ref()
            .and_then(|item| item.get("status"))
            .and_then(Value::as_str)
            .filter(|status| ["met", "partial", "missed", "invalidated"].contains(status))
            .unwrap_or("missed")
            .to_owned();
        let evidence = observations.iter().map(|row| row.0).collect::<Vec<_>>();
        sqlx::query(
            "UPDATE commitments SET status = $2, resolved_at = now(), resolution_evidence = $3 WHERE id = $1",
        )
        .bind(commitment_id)
        .bind(&status)
        .bind(&evidence)
        .execute(pool)
        .await?;
        outcome.resolved += 1;
        match status.as_str() {
            "met" => outcome.met += 1,
            "partial" => outcome.partial += 1,
            "invalidated" => outcome.invalidated += 1,
            _ => outcome.missed += 1,
        }
    }
    Ok(outcome)
}

type ObservationRow = (Uuid, DateTime<Utc>, String, String, Value);

async fn window_observations(
    pool: &PgPool,
    start: DateTime<Utc>,
    end: DateTime<Utc>,
) -> Result<Vec<ObservationRow>, sqlx::Error> {
    sqlx::query_as::<_, ObservationRow>(
        "SELECT id, observed_at, source, kind, payload FROM observations WHERE observed_at BETWEEN $1 AND $2 ORDER BY observed_at LIMIT 60",
    )
    .bind(start)
    .bind(end)
    .fetch_all(pool)
    .await
}

fn render_observations(rows: &[ObservationRow]) -> String {
    if rows.is_empty() {
        return "no records in the window".to_owned();
    }
    rows.iter()
        .map(|(_, observed_at, source, kind, payload)| {
            format!(
                "{} {source} {kind} {payload}",
                observed_at.format("%Y-%m-%d %H:%M")
            )
        })
        .collect::<Vec<_>>()
        .join("\n")
}

pub fn domain_for(claim_type: &str) -> &'static str {
    match claim_type {
        "commitment" | "intention" | "progress" => "work_estimates",
        "self_assessment" | "feeling" => "self_assessment",
        "prediction" => "risk",
        _ => "general",
    }
}

pub fn direction_for(kind: &str) -> &'static str {
    match kind {
        "overstated" => "overstated",
        "understated" => "understated",
        "timing_off" => "overstated",
        "invisible_work" => "signal_dismissed",
        _ => "accurate",
    }
}

pub async fn score_calibration(
    pool: &PgPool,
    reason: &ReasonClient,
) -> Result<DiscrepancyOutcome, Box<dyn Error + Send + Sync>> {
    if !reason.configured() {
        return Err(Box::new(ReasonError::unconfigured()));
    }
    let mut outcome = DiscrepancyOutcome::default();
    type ClaimRow = (Uuid, String, String, DateTime<Utc>);
    let claims = sqlx::query_as::<_, ClaimRow>(
        "SELECT c.id, c.statement, c.claim_type, c.asserted_at FROM claims c WHERE c.claim_type IN ('progress', 'self_assessment', 'commitment', 'prediction') AND NOT EXISTS (SELECT 1 FROM calibrations k WHERE k.claim_id = c.id) AND c.asserted_at < now() - interval '2 days' ORDER BY c.asserted_at DESC LIMIT 10",
    )
    .fetch_all(pool)
    .await?;

    for (claim_id, statement, claim_type, asserted_at) in claims {
        let observations = window_observations(
            pool,
            asserted_at - Duration::days(3),
            asserted_at + Duration::days(5),
        )
        .await?;
        if observations.is_empty() {
            continue;
        }
        let prompt = format!(
            "They said, on {}: {statement}\n\nRecords around that time:\n{}",
            asserted_at.format("%Y-%m-%d"),
            render_observations(&observations)
        );
        let answer = reason.complete(DISCREPANCY_PROMPT, &prompt).await?;
        let parsed = extract_json_array(&answer)
            .and_then(|array| array.as_array().and_then(|items| items.first().cloned()));
        let Some(item) = parsed else {
            continue;
        };
        let kind = item
            .get("kind")
            .and_then(Value::as_str)
            .filter(|kind| {
                [
                    "overstated",
                    "understated",
                    "timing_off",
                    "invisible_work",
                    "accurate",
                ]
                .contains(kind)
            })
            .unwrap_or("accurate")
            .to_owned();
        let magnitude = item
            .get("magnitude")
            .and_then(Value::as_f64)
            .unwrap_or(0.0)
            .clamp(0.0, 1.0) as f32;
        let observation_ids = observations.iter().map(|row| row.0).collect::<Vec<_>>();
        outcome.claims_checked += 1;

        if kind != "accurate" {
            sqlx::query(
                "INSERT INTO discrepancies (claim_id, observation_ids, kind, magnitude) VALUES ($1, $2, $3, $4)",
            )
            .bind(claim_id)
            .bind(&observation_ids)
            .bind(&kind)
            .bind(magnitude)
            .execute(pool)
            .await?;
            outcome.discrepancies += 1;
        }
        sqlx::query(
            "INSERT INTO calibrations (claim_id, outcome_ids, direction, magnitude, domain) VALUES ($1, $2, $3, $4, $5) ON CONFLICT (claim_id) DO NOTHING",
        )
        .bind(claim_id)
        .bind(&observation_ids)
        .bind(direction_for(&kind))
        .bind(magnitude)
        .bind(domain_for(&claim_type))
        .execute(pool)
        .await?;
        outcome.calibrations += 1;
    }
    Ok(outcome)
}

pub async fn calibration_profile(pool: &PgPool) -> Result<Vec<CalibrationSummary>, sqlx::Error> {
    let rows = sqlx::query_as::<_, (String, String, i64, Option<f32>)>(
        "SELECT domain, direction, count(*), avg(magnitude)::real FROM calibrations GROUP BY domain, direction ORDER BY count(*) DESC",
    )
    .fetch_all(pool)
    .await?;
    Ok(rows
        .into_iter()
        .map(
            |(domain, direction, samples, average_magnitude)| CalibrationSummary {
                domain,
                direction,
                samples,
                average_magnitude: average_magnitude.unwrap_or(0.0),
            },
        )
        .collect())
}

pub async fn commitments(pool: &PgPool, limit: i64) -> Result<Vec<CommitmentRow>, sqlx::Error> {
    type Row = (
        Uuid,
        String,
        DateTime<Utc>,
        DateTime<Utc>,
        String,
        Value,
        Option<DateTime<Utc>>,
        Option<String>,
    );
    let rows = sqlx::query_as::<_, Row>(
        "SELECT m.id, c.statement, m.stated_at, m.due_by, m.status, m.observable, m.resolved_at, m.user_override FROM commitments m JOIN claims c ON c.id = m.claim_id ORDER BY m.due_by DESC LIMIT $1",
    )
    .bind(limit)
    .fetch_all(pool)
    .await?;
    Ok(rows
        .into_iter()
        .map(|row| CommitmentRow {
            id: row.0,
            claim: row.1,
            stated_at: row.2,
            due_by: row.3,
            status: row.4,
            observable: row.5,
            resolved_at: row.6,
            user_override: row.7,
        })
        .collect())
}

pub async fn discrepancies(pool: &PgPool, limit: i64) -> Result<Vec<DiscrepancyRow>, sqlx::Error> {
    type Row = (
        Uuid,
        String,
        String,
        f32,
        DateTime<Utc>,
        bool,
        Option<String>,
    );
    let rows = sqlx::query_as::<_, Row>(
        "SELECT d.id, c.statement, d.kind, d.magnitude, d.detected_at, d.dismissed, d.user_response FROM discrepancies d JOIN claims c ON c.id = d.claim_id ORDER BY d.detected_at DESC LIMIT $1",
    )
    .bind(limit)
    .fetch_all(pool)
    .await?;
    Ok(rows
        .into_iter()
        .map(|row| DiscrepancyRow {
            id: row.0,
            claim: row.1,
            kind: row.2,
            magnitude: row.3,
            detected_at: row.4,
            dismissed: row.5,
            user_response: row.6,
        })
        .collect())
}

pub async fn override_discrepancy(
    pool: &PgPool,
    id: Uuid,
    real: &str,
) -> Result<bool, sqlx::Error> {
    let updated = sqlx::query(
        "UPDATE discrepancies SET user_response = $2, dismissed = true, kind = 'invisible_work' WHERE id = $1",
    )
    .bind(id)
    .bind(real)
    .execute(pool)
    .await?;
    if updated.rows_affected() == 0 {
        return Ok(false);
    }
    sqlx::query(
        "UPDATE calibrations SET direction = 'signal_dismissed' WHERE claim_id = (SELECT claim_id FROM discrepancies WHERE id = $1)",
    )
    .bind(id)
    .execute(pool)
    .await?;
    sqlx::query(
        "UPDATE commitments SET user_override = $2, status = CASE WHEN status = 'missed' THEN 'met' ELSE status END WHERE claim_id = (SELECT claim_id FROM discrepancies WHERE id = $1)",
    )
    .bind(id)
    .bind(real)
    .execute(pool)
    .await?;
    Ok(true)
}

#[cfg(test)]
mod tests {
    use super::{direction_for, domain_for};

    #[test]
    fn work_and_self_assessment_calibrate_separately() {
        assert_eq!(domain_for("commitment"), "work_estimates");
        assert_eq!(domain_for("self_assessment"), "self_assessment");
        assert_eq!(domain_for("prediction"), "risk");
    }

    #[test]
    fn being_hard_on_yourself_is_tracked_too() {
        assert_eq!(direction_for("understated"), "understated");
        assert_eq!(direction_for("overstated"), "overstated");
        assert_eq!(direction_for("invisible_work"), "signal_dismissed");
        assert_eq!(direction_for("accurate"), "accurate");
    }
}
