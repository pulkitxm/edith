use std::env;
use std::time::Duration;

use chrono::{Local, NaiveTime, Timelike};
use serde_json::{Value, json};
use sqlx::PgPool;
use uuid::Uuid;

use crate::baseline::rescore;
use crate::claims::{corroborate_claims, extract_claims};
use crate::embed::EmbedClient;

use crate::indexer::index_pending;
use crate::{commitments, core_memory, entities, facts, hypotheses, inquire, lenses};
use crate::reflect::reflect_run;
use crate::settings::{ConnectorHandle, ReasonHandle};

#[derive(Clone)]
pub struct NightlyDeps {
    pub pool: PgPool,
    pub vault_dir: String,
    pub embed: EmbedClient,
    pub reason: ReasonHandle,
    pub connectors: ConnectorHandle,
}

fn step(name: &str, result: Result<Value, String>) -> Value {
    match result {
        Ok(detail) => json!({"name": name, "ok": true, "detail": detail}),
        Err(error) => json!({"name": name, "ok": false, "detail": error}),
    }
}

pub async fn run_pipeline(deps: &NightlyDeps) -> (bool, Vec<Value>) {
    let mut steps = Vec::new();

    let github = deps.connectors.github().await;
    if github.configured() {
        let result = github
            .sync(&deps.pool)
            .await
            .map(|outcome| serde_json::to_value(outcome).unwrap_or(Value::Null))
            .map_err(|error| error.to_string());
        steps.push(step("sync_github", result));
    } else {
        steps.push(step("sync_github", Ok(json!("skipped, no token"))));
    }

    let notion = deps.connectors.notion().await;
    if notion.configured() {
        let result = notion
            .sync(&deps.pool, std::path::Path::new(&deps.vault_dir), false)
            .await
            .map(|outcome| serde_json::to_value(outcome).unwrap_or(Value::Null))
            .map_err(|error| error.to_string());
        steps.push(step("sync_notion", result));
    } else {
        steps.push(step("sync_notion", Ok(json!("skipped, no token"))));
    }

    let result = index_pending(&deps.pool, &deps.embed)
        .await
        .map(|outcome| serde_json::to_value(outcome).unwrap_or(Value::Null))
        .map_err(|error| error.to_string());
    steps.push(step("index", result));

    let result = rescore(&deps.pool)
        .await
        .map(|outcome| serde_json::to_value(outcome).unwrap_or(Value::Null))
        .map_err(|error| error.to_string());
    steps.push(step("baselines", result));

    let reason = deps.reason.current().await;
    if !reason.configured() {
        steps.push(step("reasoning", Ok(json!("skipped, no provider"))));
        let ok = steps
            .iter()
            .all(|entry| entry.get("ok").and_then(Value::as_bool).unwrap_or(false));
        return (ok, steps);
    }

    let result = extract_claims(&deps.pool, &reason)
        .await
        .map(|outcome| serde_json::to_value(outcome).unwrap_or(Value::Null))
        .map_err(|error| error.to_string());
    steps.push(step("extract_claims", result));

    let result = entities::extract(&deps.pool, &deps.embed, &reason)
        .await
        .map(|outcome| serde_json::to_value(outcome).unwrap_or(Value::Null))
        .map_err(|error| error.to_string());
    steps.push(step("entities", result));

    let result = facts::extract(&deps.pool, &deps.embed, &reason)
        .await
        .map(|outcome| serde_json::to_value(outcome).unwrap_or(Value::Null))
        .map_err(|error| error.to_string());
    steps.push(step("facts", result));

    let result = corroborate_claims(&deps.pool, &reason)
        .await
        .map(|outcome| serde_json::to_value(outcome).unwrap_or(Value::Null))
        .map_err(|error| error.to_string());
    steps.push(step("corroborate", result));

    let result = commitments::track(&deps.pool, &reason)
        .await
        .map(|outcome| serde_json::to_value(outcome).unwrap_or(Value::Null))
        .map_err(|error| error.to_string());
    steps.push(step("commitments", result));

    let result = commitments::score_calibration(&deps.pool, &reason)
        .await
        .map(|outcome| serde_json::to_value(outcome).unwrap_or(Value::Null))
        .map_err(|error| error.to_string());
    steps.push(step("calibration", result));

    let result = reflect_run(&deps.pool, &deps.embed, &reason)
        .await
        .map(|outcome| serde_json::to_value(outcome).unwrap_or(Value::Null))
        .map_err(|error| error.to_string());
    steps.push(step("reflect", result));

    let result = hypotheses::resolve_due(&deps.pool, &reason)
        .await
        .map(|outcome| serde_json::to_value(outcome).unwrap_or(Value::Null))
        .map_err(|error| error.to_string());
    steps.push(step("resolve_predictions", result));

    let result = hypotheses::generate(&deps.pool, &deps.embed, &reason)
        .await
        .map(|outcome| serde_json::to_value(outcome).unwrap_or(Value::Null))
        .map_err(|error| error.to_string());
    steps.push(step("hypotheses", result));

    let result = core_memory::rewrite(&deps.pool, &reason)
        .await
        .map(|outcome| serde_json::to_value(outcome).unwrap_or(Value::Null))
        .map_err(|error| error.to_string());
    steps.push(step("core_memory", result));

    let result = lenses::rewrite(&deps.pool, &reason)
        .await
        .map(|outcome| serde_json::to_value(outcome).unwrap_or(Value::Null))
        .map_err(|error| error.to_string());
    steps.push(step("persona_lenses", result));

    let result = inquire::rank(&deps.pool, &reason)
        .await
        .map(|outcome| serde_json::to_value(outcome).unwrap_or(Value::Null))
        .map_err(|error| error.to_string());
    steps.push(step("inquiry", result));

    let ok = steps
        .iter()
        .all(|entry| entry.get("ok").and_then(Value::as_bool).unwrap_or(false));
    (ok, steps)
}

pub async fn record_run(deps: &NightlyDeps) -> Result<Uuid, sqlx::Error> {
    let run_id =
        sqlx::query_scalar::<_, Uuid>("INSERT INTO nightly_runs DEFAULT VALUES RETURNING id")
            .fetch_one(&deps.pool)
            .await?;
    let (ok, steps) = run_pipeline(deps).await;
    sqlx::query("UPDATE nightly_runs SET finished_at = now(), ok = $2, steps = $3 WHERE id = $1")
        .bind(run_id)
        .bind(ok)
        .bind(Value::Array(steps))
        .execute(&deps.pool)
        .await?;
    Ok(run_id)
}

pub fn seconds_until_next(now_seconds_of_day: u32, at: NaiveTime) -> u64 {
    let target = at.num_seconds_from_midnight();
    let day = 24 * 60 * 60;
    if target > now_seconds_of_day {
        (target - now_seconds_of_day) as u64
    } else {
        (day - now_seconds_of_day + target) as u64
    }
}

pub fn spawn_scheduler(deps: NightlyDeps) {
    let every_override = env::var("COMPANION_SCHEDULE_EVERY_SECONDS")
        .ok()
        .and_then(|value| value.parse::<u64>().ok())
        .filter(|seconds| *seconds >= 30);
    let at = env::var("COMPANION_REFLECT_AT")
        .ok()
        .and_then(|value| NaiveTime::parse_from_str(&value, "%H:%M").ok())
        .unwrap_or_else(|| NaiveTime::from_hms_opt(2, 0, 0).unwrap());

    tokio::spawn(async move {
        loop {
            let wait = match every_override {
                Some(seconds) => seconds,
                None => {
                    let now = Local::now().time().num_seconds_from_midnight();
                    seconds_until_next(now, at)
                }
            };
            tokio::time::sleep(Duration::from_secs(wait)).await;
            match record_run(&deps).await {
                Ok(run_id) => println!("nightly run {run_id} finished"),
                Err(error) => eprintln!("nightly run failed to record: {error}"),
            }
        }
    });
}

#[cfg(test)]
mod tests {
    use super::seconds_until_next;
    use chrono::NaiveTime;

    #[test]
    fn waits_until_tonight_when_target_is_ahead() {
        let at = NaiveTime::from_hms_opt(2, 0, 0).unwrap();
        assert_eq!(seconds_until_next(0, at), 7200);
    }

    #[test]
    fn rolls_to_tomorrow_when_target_has_passed() {
        let at = NaiveTime::from_hms_opt(2, 0, 0).unwrap();
        let day = 24 * 60 * 60;
        assert_eq!(seconds_until_next(3 * 60 * 60, at), day - 3600);
    }
}
