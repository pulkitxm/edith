use std::error::Error;

use chrono::{DateTime, Duration, Utc};
use serde::Serialize;
use serde_json::Value;
use sqlx::PgPool;
use uuid::Uuid;

use crate::claims::{corroborate_claims, extract_claims};
use crate::commitments;
use crate::ingest::{IngestFile, ingest_files};
use crate::reason::{ReasonClient, ReasonError};

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct StandupClaim {
    pub id: Uuid,
    pub statement: String,
    pub claim_type: String,
    pub testable: bool,
    pub verdict: Option<String>,
    pub note: Option<String>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct StandupOutcome {
    pub episode_id: Uuid,
    pub occurred_at: DateTime<Utc>,
    pub claims: Vec<StandupClaim>,
    pub verified: bool,
    pub aggregate: Option<AggregateRow>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AggregateRow {
    pub standups: i64,
    pub commitments_resolved: i64,
    pub met_rate: f32,
    pub median_slip_days: Option<f64>,
    pub overstated: i64,
    pub understated: i64,
    pub invisible_work: i64,
}

pub fn title_for(occurred_at: DateTime<Utc>) -> String {
    format!("Standup {}", occurred_at.format("%Y-%m-%d"))
}

pub async fn record(
    pool: &PgPool,
    vault_dir: &std::path::Path,
    reason: &ReasonClient,
    text: &str,
    verify: bool,
) -> Result<StandupOutcome, Box<dyn Error + Send + Sync>> {
    let now = Utc::now();
    let name = format!("standups/{}.md", now.format("%Y-%m-%dT%H%M%S"));
    let body = format!(
        "---\ntitle: {}\ndate: {}\nkind: standup\n---\n\n{}",
        title_for(now),
        now.to_rfc3339(),
        text.trim()
    );
    let ingested = ingest_files(
        pool,
        vault_dir,
        vec![IngestFile {
            name,
            text: body,
            mtime: Some(now.to_rfc3339()),
        }],
    )
    .await?;
    let Some(first) = ingested.into_iter().next() else {
        return Err("the standup produced no episode".into());
    };
    sqlx::query("UPDATE episodes SET kind = 'standup' WHERE id = $1")
        .bind(first.episode_id)
        .execute(pool)
        .await?;

    if reason.configured() {
        extract_claims(pool, reason).await?;
        if verify {
            corroborate_claims(pool, reason).await?;
            commitments::track(pool, reason).await?;
            commitments::score_calibration(pool, reason).await?;
        }
    } else if verify {
        return Err(Box::new(ReasonError::unconfigured()));
    }

    type ClaimRow = (Uuid, String, String, bool, Option<String>, Option<String>);
    let claims = sqlx::query_as::<_, ClaimRow>(
        "SELECT c.id, c.statement, c.claim_type, c.testable, x.verdict, x.note FROM claims c LEFT JOIN LATERAL (SELECT verdict, note FROM corroborations WHERE claim_id = c.id ORDER BY checked_at DESC LIMIT 1) x ON true WHERE c.episode_id = $1 ORDER BY c.asserted_at",
    )
    .bind(first.episode_id)
    .fetch_all(pool)
    .await?;

    Ok(StandupOutcome {
        episode_id: first.episode_id,
        occurred_at: first.occurred_at,
        claims: claims
            .into_iter()
            .map(
                |(id, statement, claim_type, testable, verdict, note)| StandupClaim {
                    id,
                    statement,
                    claim_type,
                    testable,
                    verdict,
                    note,
                },
            )
            .collect(),
        verified: verify,
        aggregate: aggregate(pool).await.ok(),
    })
}

pub async fn aggregate(pool: &PgPool) -> Result<AggregateRow, sqlx::Error> {
    let standups =
        sqlx::query_scalar::<_, i64>("SELECT count(*) FROM episodes WHERE kind = 'standup'")
            .fetch_one(pool)
            .await?;
    type Row = (i64, i64, Option<f64>);
    let (resolved, met, slip) = sqlx::query_as::<_, Row>(
        "SELECT count(*) FILTER (WHERE status <> 'open'), count(*) FILTER (WHERE status = 'met'), percentile_cont(0.5) WITHIN GROUP (ORDER BY extract(epoch FROM (resolved_at - due_by)) / 86400.0)::float8 FROM commitments WHERE status <> 'open'",
    )
    .fetch_one(pool)
    .await?;
    type Directions = (i64, i64, i64);
    let (overstated, understated, invisible) = sqlx::query_as::<_, Directions>(
        "SELECT count(*) FILTER (WHERE kind = 'overstated'), count(*) FILTER (WHERE kind = 'understated'), count(*) FILTER (WHERE kind = 'invisible_work') FROM discrepancies",
    )
    .fetch_one(pool)
    .await?;

    Ok(AggregateRow {
        standups,
        commitments_resolved: resolved,
        met_rate: if resolved == 0 {
            0.0
        } else {
            met as f32 / resolved as f32
        },
        median_slip_days: slip,
        overstated,
        understated,
        invisible_work: invisible,
    })
}

pub async fn phrase_history(pool: &PgPool, phrase: &str) -> Result<Value, sqlx::Error> {
    let pattern = format!("%{}%", phrase.to_lowercase());
    type Row = (Uuid, DateTime<Utc>, String, Option<DateTime<Utc>>, Option<String>);
    let rows = sqlx::query_as::<_, Row>(
        "SELECT c.id, c.asserted_at, c.statement, m.resolved_at, m.status FROM claims c LEFT JOIN commitments m ON m.claim_id = c.id WHERE lower(c.statement) LIKE $1 ORDER BY c.asserted_at DESC LIMIT 200",
    )
    .bind(&pattern)
    .fetch_all(pool)
    .await?;
    let mut days = rows
        .iter()
        .filter_map(|(_, asserted_at, _, resolved_at, _)| {
            resolved_at.map(|resolved| (resolved - *asserted_at).num_days() as f64)
        })
        .collect::<Vec<_>>();
    days.sort_by(|left, right| left.partial_cmp(right).unwrap_or(std::cmp::Ordering::Equal));
    let median = if days.is_empty() {
        None
    } else {
        Some(days[days.len() / 2])
    };
    Ok(serde_json::json!({
        "phrase": phrase,
        "occurrences": rows.len(),
        "resolved": days.len(),
        "medianWorkingDays": median,
    }))
}

pub async fn due_soon(pool: &PgPool) -> Result<i64, sqlx::Error> {
    sqlx::query_scalar::<_, i64>(
        "SELECT count(*) FROM commitments WHERE status = 'open' AND due_by <= $1",
    )
    .bind(Utc::now() + Duration::days(1))
    .fetch_one(pool)
    .await
}

#[cfg(test)]
mod tests {
    use super::title_for;
    use chrono::{TimeZone, Utc};

    #[test]
    fn a_standup_is_titled_by_its_day() {
        let when = Utc.with_ymd_and_hms(2026, 8, 10, 9, 30, 0).unwrap();
        assert_eq!(title_for(when), "Standup 2026-08-10");
    }
}
