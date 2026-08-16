use std::error::Error;
use std::fmt::{Display, Formatter};

use chrono::{DateTime, Utc};
use reqwest::Client;
use serde::Serialize;
use serde_json::Value;
use sqlx::PgPool;

#[derive(Debug)]
pub struct GithubError(String);

impl Display for GithubError {
    fn fmt(&self, formatter: &mut Formatter<'_>) -> std::fmt::Result {
        formatter.write_str(&self.0)
    }
}

impl Error for GithubError {}

#[derive(Clone)]
pub struct GithubConnector {
    client: Client,
    token: Option<String>,
}

#[derive(Debug, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SyncOutcome {
    pub events_fetched: usize,
    pub observations_inserted: usize,
}

struct PendingObservation {
    dedupe_key: String,
    kind: &'static str,
    observed_at: DateTime<Utc>,
    payload: Value,
}

impl GithubConnector {
    pub fn with_token(token: &str) -> Self {
        Self {
            client: Client::new(),
            token: Some(token.trim().to_owned()).filter(|token| !token.is_empty()),
        }
    }

    pub fn describe(&self) -> String {
        match &self.token {
            Some(token) => crate::settings::hint(token).unwrap_or_else(|| "set".to_owned()),
            None => "no token; set it from the app or `ed companion connectors set`".to_owned(),
        }
    }

    pub fn configured(&self) -> bool {
        self.token.is_some()
    }

    async fn login(&self, token: &str) -> Result<String, GithubError> {
        let response = self
            .client
            .get("https://api.github.com/user")
            .header("Authorization", format!("Bearer {token}"))
            .header("Accept", "application/vnd.github+json")
            .header("User-Agent", "edith-companion")
            .header("X-GitHub-Api-Version", "2022-11-28")
            .send()
            .await
            .map_err(|error| GithubError(format!("GitHub request failed: {error}")))?;
        let status = response.status();
        let body = response
            .text()
            .await
            .map_err(|error| GithubError(format!("GitHub response unreadable: {error}")))?;
        if !status.is_success() {
            return Err(GithubError(format!("GitHub returned {status}: {body}")));
        }
        serde_json::from_str::<Value>(&body)
            .ok()
            .and_then(|user| user.get("login").and_then(Value::as_str).map(str::to_owned))
            .ok_or_else(|| GithubError("GitHub user response had no login".to_owned()))
    }

    async fn events_page(
        &self,
        token: &str,
        login: &str,
        page: u32,
    ) -> Result<Vec<Value>, GithubError> {
        let response = self
            .client
            .get(format!(
                "https://api.github.com/users/{login}/events?per_page=100&page={page}"
            ))
            .header("Authorization", format!("Bearer {token}"))
            .header("Accept", "application/vnd.github+json")
            .header("User-Agent", "edith-companion")
            .header("X-GitHub-Api-Version", "2022-11-28")
            .send()
            .await
            .map_err(|error| GithubError(format!("GitHub request failed: {error}")))?;
        let status = response.status();
        let body = response
            .text()
            .await
            .map_err(|error| GithubError(format!("GitHub response unreadable: {error}")))?;
        if !status.is_success() {
            return Err(GithubError(format!("GitHub returned {status}: {body}")));
        }
        serde_json::from_str::<Vec<Value>>(&body)
            .map_err(|error| GithubError(format!("Invalid GitHub response: {error}")))
    }

    pub async fn sync(&self, pool: &PgPool) -> Result<SyncOutcome, Box<dyn Error + Send + Sync>> {
        let token = self
            .token
            .as_deref()
            .ok_or_else(|| GithubError("GITHUB_TOKEN is not configured".to_owned()))?;

        let login = self.login(token).await?;
        let mut outcome = SyncOutcome::default();
        for page in 1..=3 {
            let events = self.events_page(token, &login, page).await?;
            if events.is_empty() {
                break;
            }
            outcome.events_fetched += events.len();
            for event in &events {
                for pending in observations_for(event) {
                    let inserted = sqlx::query_scalar::<_, i32>(
                        "INSERT INTO observations (source, observed_at, kind, payload, dedupe_key) VALUES ('github', $1, $2, $3, $4) ON CONFLICT (dedupe_key) WHERE dedupe_key IS NOT NULL DO NOTHING RETURNING 1",
                    )
                    .bind(pending.observed_at)
                    .bind(pending.kind)
                    .bind(&pending.payload)
                    .bind(&pending.dedupe_key)
                    .fetch_optional(pool)
                    .await?;
                    if inserted.is_some() {
                        outcome.observations_inserted += 1;
                    }
                }
            }
        }
        Ok(outcome)
    }
}

fn event_time(event: &Value) -> Option<DateTime<Utc>> {
    event
        .get("created_at")
        .and_then(Value::as_str)
        .and_then(|value| DateTime::parse_from_rfc3339(value).ok())
        .map(|value| value.with_timezone(&Utc))
}

fn repo_name(event: &Value) -> String {
    event
        .pointer("/repo/name")
        .and_then(Value::as_str)
        .unwrap_or("unknown")
        .to_owned()
}

fn observations_for(event: &Value) -> Vec<PendingObservation> {
    let Some(event_type) = event.get("type").and_then(Value::as_str) else {
        return Vec::new();
    };
    let Some(observed_at) = event_time(event) else {
        return Vec::new();
    };
    let repo = repo_name(event);

    match event_type {
        "PushEvent" => {
            let commits = event
                .pointer("/payload/commits")
                .and_then(Value::as_array)
                .cloned()
                .unwrap_or_default();
            commits
                .iter()
                .filter_map(|commit| {
                    let sha = commit.get("sha").and_then(Value::as_str)?;
                    let message = commit
                        .get("message")
                        .and_then(Value::as_str)
                        .unwrap_or_default()
                        .lines()
                        .next()
                        .unwrap_or_default();
                    Some(PendingObservation {
                        dedupe_key: format!("github:commit:{sha}"),
                        kind: "commit",
                        observed_at,
                        payload: serde_json::json!({
                            "repo": repo,
                            "sha": sha,
                            "message": message,
                        }),
                    })
                })
                .collect()
        }
        "PullRequestEvent" => {
            let action = event
                .pointer("/payload/action")
                .and_then(Value::as_str)
                .unwrap_or("unknown");
            let Some(number) = event
                .pointer("/payload/pull_request/number")
                .and_then(Value::as_i64)
            else {
                return Vec::new();
            };
            let title = event
                .pointer("/payload/pull_request/title")
                .and_then(Value::as_str)
                .unwrap_or_default();
            let merged = event
                .pointer("/payload/pull_request/merged")
                .and_then(Value::as_bool)
                .unwrap_or(false);
            vec![PendingObservation {
                dedupe_key: format!("github:pr:{repo}:{number}:{action}:{merged}"),
                kind: "pull_request",
                observed_at,
                payload: serde_json::json!({
                    "repo": repo,
                    "number": number,
                    "title": title,
                    "action": action,
                    "merged": merged,
                }),
            }]
        }
        "IssuesEvent" => {
            let action = event
                .pointer("/payload/action")
                .and_then(Value::as_str)
                .unwrap_or("unknown");
            let Some(number) = event
                .pointer("/payload/issue/number")
                .and_then(Value::as_i64)
            else {
                return Vec::new();
            };
            let title = event
                .pointer("/payload/issue/title")
                .and_then(Value::as_str)
                .unwrap_or_default();
            vec![PendingObservation {
                dedupe_key: format!("github:issue:{repo}:{number}:{action}"),
                kind: "issue",
                observed_at,
                payload: serde_json::json!({
                    "repo": repo,
                    "number": number,
                    "title": title,
                    "action": action,
                }),
            }]
        }
        "PullRequestReviewEvent" => {
            let Some(review_id) = event.pointer("/payload/review/id").and_then(Value::as_i64)
            else {
                return Vec::new();
            };
            let number = event
                .pointer("/payload/pull_request/number")
                .and_then(Value::as_i64)
                .unwrap_or_default();
            let state = event
                .pointer("/payload/review/state")
                .and_then(Value::as_str)
                .unwrap_or_default();
            vec![PendingObservation {
                dedupe_key: format!("github:review:{review_id}"),
                kind: "review",
                observed_at,
                payload: serde_json::json!({
                    "repo": repo,
                    "number": number,
                    "state": state,
                }),
            }]
        }
        _ => Vec::new(),
    }
}

#[cfg(test)]
mod tests {
    use super::observations_for;

    #[test]
    fn push_event_yields_one_observation_per_commit() {
        let event = serde_json::json!({
            "type": "PushEvent",
            "created_at": "2026-08-09T10:00:00Z",
            "repo": {"name": "pulkitxm/edith"},
            "payload": {"commits": [
                {"sha": "abc123", "message": "First line\nrest"},
                {"sha": "def456", "message": "Second"},
            ]},
        });
        let observations = observations_for(&event);
        assert_eq!(observations.len(), 2);
        assert_eq!(observations[0].dedupe_key, "github:commit:abc123");
        assert_eq!(observations[0].payload["message"], "First line");
    }

    #[test]
    fn unknown_events_yield_nothing() {
        let event = serde_json::json!({
            "type": "WatchEvent",
            "created_at": "2026-08-09T10:00:00Z",
            "repo": {"name": "pulkitxm/edith"},
        });
        assert!(observations_for(&event).is_empty());
    }

    #[test]
    fn pull_request_event_keys_on_action() {
        let event = serde_json::json!({
            "type": "PullRequestEvent",
            "created_at": "2026-08-09T10:00:00Z",
            "repo": {"name": "pulkitxm/edith"},
            "payload": {"action": "closed", "pull_request": {"number": 7, "title": "T", "merged": true}},
        });
        let observations = observations_for(&event);
        assert_eq!(observations.len(), 1);
        assert_eq!(
            observations[0].dedupe_key,
            "github:pr:pulkitxm/edith:7:closed:true"
        );
    }
}
