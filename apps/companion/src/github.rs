use std::error::Error;
use std::fmt::{Display, Formatter};
use std::sync::Arc;
use std::time::Duration;

use chrono::{DateTime, Utc};
use futures_util::StreamExt;
use reqwest::{Client, Response};
use serde::Serialize;
use serde::de::DeserializeOwned;
use serde_json::Value;
use sqlx::{PgPool, Postgres, QueryBuilder};
use tokio::sync::OnceCell;

const CONNECT_TIMEOUT: Duration = Duration::from_secs(5);
const REQUEST_TIMEOUT: Duration = Duration::from_secs(15);
const RESPONSE_BYTE_LIMIT: usize = 8 * 1024 * 1024;
const ERROR_DETAIL_BYTE_LIMIT: usize = 1024;
const INSERT_BATCH_SIZE: usize = 250;

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
    login: Arc<OnceCell<String>>,
}

#[derive(Clone, Debug, Default, Serialize)]
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
            client: Client::builder()
                .connect_timeout(CONNECT_TIMEOUT)
                .timeout(REQUEST_TIMEOUT)
                .build()
                .expect("static GitHub client configuration must build"),
            token: Some(token.trim().to_owned()).filter(|token| !token.is_empty()),
            login: Arc::new(OnceCell::new()),
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

    async fn login(&self, token: &str) -> Result<&str, GithubError> {
        self.login
            .get_or_try_init(|| async {
                let user: Value = self.get_json("https://api.github.com/user", token).await?;
                user.get("login")
                    .and_then(Value::as_str)
                    .map(str::to_owned)
                    .ok_or_else(|| GithubError("GitHub user response had no login".to_owned()))
            })
            .await
            .map(String::as_str)
    }

    async fn events_page(
        &self,
        token: &str,
        login: &str,
        page: u32,
    ) -> Result<Vec<Value>, GithubError> {
        self.get_json(
            &format!("https://api.github.com/users/{login}/events?per_page=100&page={page}"),
            token,
        )
        .await
    }

    async fn get_json<T: DeserializeOwned>(
        &self,
        url: &str,
        token: &str,
    ) -> Result<T, GithubError> {
        let response = self
            .client
            .get(url)
            .header("Authorization", format!("Bearer {token}"))
            .header("Accept", "application/vnd.github+json")
            .header("User-Agent", "edith-companion")
            .header("X-GitHub-Api-Version", "2022-11-28")
            .send()
            .await
            .map_err(|error| GithubError(format!("GitHub request failed: {error}")))?;
        let status = response.status();
        let body = bounded_body(response).await?;
        if !status.is_success() {
            let detail = String::from_utf8_lossy(&body[..body.len().min(ERROR_DETAIL_BYTE_LIMIT)]);
            return Err(GithubError(format!("GitHub returned {status}: {detail}")));
        }
        serde_json::from_slice(&body)
            .map_err(|error| GithubError(format!("Invalid GitHub response: {error}")))
    }

    pub async fn sync(&self, pool: &PgPool) -> Result<SyncOutcome, Box<dyn Error + Send + Sync>> {
        let token = self
            .token
            .as_deref()
            .ok_or_else(|| GithubError("GITHUB_TOKEN is not configured".to_owned()))?;

        let login = self.login(token).await?.to_owned();
        let mut outcome = SyncOutcome::default();
        for page in 1..=3 {
            let events = self.events_page(token, &login, page).await?;
            if events.is_empty() {
                break;
            }
            outcome.events_fetched += events.len();
            let pending = events.iter().flat_map(observations_for).collect::<Vec<_>>();
            outcome.observations_inserted += insert_observations(pool, &pending).await?;
        }
        Ok(outcome)
    }
}

async fn bounded_body(response: Response) -> Result<Vec<u8>, GithubError> {
    if response
        .content_length()
        .is_some_and(|length| length > RESPONSE_BYTE_LIMIT as u64)
    {
        return Err(GithubError(format!(
            "GitHub response exceeded {RESPONSE_BYTE_LIMIT} bytes"
        )));
    }
    let capacity = response
        .content_length()
        .map(|length| length.min(RESPONSE_BYTE_LIMIT as u64) as usize)
        .unwrap_or(0);
    let mut body = Vec::with_capacity(capacity);
    let mut stream = response.bytes_stream();
    while let Some(chunk) = stream.next().await {
        let chunk =
            chunk.map_err(|error| GithubError(format!("GitHub response unreadable: {error}")))?;
        append_bounded(&mut body, &chunk, RESPONSE_BYTE_LIMIT)?;
    }
    Ok(body)
}

fn append_bounded(body: &mut Vec<u8>, chunk: &[u8], byte_limit: usize) -> Result<(), GithubError> {
    if chunk.len() > byte_limit.saturating_sub(body.len()) {
        return Err(GithubError(format!(
            "GitHub response exceeded {byte_limit} bytes"
        )));
    }
    body.extend_from_slice(chunk);
    Ok(())
}

async fn insert_observations(
    pool: &PgPool,
    pending: &[PendingObservation],
) -> Result<usize, sqlx::Error> {
    let mut inserted = 0usize;
    for batch_index in 0..insertion_batch_count(pending.len()) {
        let start = batch_index * INSERT_BATCH_SIZE;
        let end = (start + INSERT_BATCH_SIZE).min(pending.len());
        let chunk = &pending[start..end];
        let mut query = QueryBuilder::<Postgres>::new(
            "INSERT INTO observations (source, observed_at, kind, payload, dedupe_key) ",
        );
        query.push_values(chunk, |mut row, pending| {
            row.push_bind("github")
                .push_bind(pending.observed_at)
                .push_bind(pending.kind)
                .push_bind(&pending.payload)
                .push_bind(&pending.dedupe_key);
        });
        query.push(" ON CONFLICT (dedupe_key) WHERE dedupe_key IS NOT NULL DO NOTHING");
        inserted =
            inserted.saturating_add(query.build().execute(pool).await?.rows_affected() as usize);
    }
    Ok(inserted)
}

fn insertion_batch_count(observation_count: usize) -> usize {
    observation_count.div_ceil(INSERT_BATCH_SIZE)
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
    use super::{append_bounded, insertion_batch_count, observations_for};

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

    #[test]
    fn response_body_limit_applies_across_chunks() {
        let mut body = vec![0; 6];
        append_bounded(&mut body, &[1, 2], 8).unwrap();
        assert_eq!(body.len(), 8);
        assert!(append_bounded(&mut body, &[3], 8).is_err());
    }

    #[test]
    fn large_history_inserts_have_a_fixed_round_trip_bound() {
        assert_eq!(insertion_batch_count(0), 0);
        assert_eq!(insertion_batch_count(250), 1);
        assert_eq!(insertion_batch_count(251), 2);
        assert_eq!(insertion_batch_count(6000), 24);
    }
}
