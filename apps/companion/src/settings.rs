use std::collections::HashMap;
use std::sync::Arc;

use sqlx::PgPool;
use tokio::sync::RwLock;

use crate::reason::{ReasonClient, ReasonConfig};

pub const REASON_PROVIDER: &str = "reason.provider";
pub const REASON_URL: &str = "reason.url";
pub const REASON_MODEL: &str = "reason.model";
pub const REASON_API_KEY: &str = "reason.api_key";
pub const GITHUB_TOKEN: &str = "connector.github_token";
pub const NOTION_TOKEN: &str = "connector.notion_token";

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct ConnectorTokens {
    pub github: String,
    pub notion: String,
}

impl ConnectorTokens {
    pub fn from_env() -> Self {
        Self {
            github: std::env::var("GITHUB_TOKEN").unwrap_or_default(),
            notion: std::env::var("NOTION_TOKEN").unwrap_or_default(),
        }
    }
}

pub fn hint(token: &str) -> Option<String> {
    let trimmed = token.trim();
    if trimmed.is_empty() {
        return None;
    }
    let tail = trimmed
        .chars()
        .rev()
        .take(4)
        .collect::<String>()
        .chars()
        .rev()
        .collect::<String>();
    Some(format!("set, ending {tail}"))
}

pub fn connector_tokens_from(
    env: ConnectorTokens,
    stored: &HashMap<String, String>,
) -> ConnectorTokens {
    let pick = |key: &str, fallback: String| {
        stored
            .get(key)
            .cloned()
            .filter(|value| !value.is_empty())
            .unwrap_or(fallback)
    };
    ConnectorTokens {
        github: pick(GITHUB_TOKEN, env.github),
        notion: pick(NOTION_TOKEN, env.notion),
    }
}

pub async fn connector_tokens(pool: &PgPool) -> ConnectorTokens {
    let stored = load_all(pool).await.unwrap_or_default();
    connector_tokens_from(ConnectorTokens::from_env(), &stored)
}

pub async fn load_all(pool: &PgPool) -> Result<HashMap<String, String>, sqlx::Error> {
    let rows = sqlx::query_as::<_, (String, String)>("SELECT key, value FROM settings")
        .fetch_all(pool)
        .await?;
    Ok(rows.into_iter().collect())
}

pub async fn put(pool: &PgPool, key: &str, value: &str) -> Result<(), sqlx::Error> {
    sqlx::query(
        "INSERT INTO settings (key, value) VALUES ($1, $2) ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = now()",
    )
    .bind(key)
    .bind(value)
    .execute(pool)
    .await?;
    Ok(())
}

pub async fn remove(pool: &PgPool, key: &str) -> Result<(), sqlx::Error> {
    sqlx::query("DELETE FROM settings WHERE key = $1")
        .bind(key)
        .execute(pool)
        .await?;
    Ok(())
}

pub fn reason_config_from(env: ReasonConfig, stored: &HashMap<String, String>) -> ReasonConfig {
    let pick = |key: &str, fallback: String| {
        stored
            .get(key)
            .cloned()
            .filter(|value| !value.is_empty())
            .unwrap_or(fallback)
    };
    ReasonConfig {
        provider: pick(REASON_PROVIDER, env.provider),
        url: pick(REASON_URL, env.url),
        model: pick(REASON_MODEL, env.model),
        api_key: pick(REASON_API_KEY, env.api_key),
    }
}

pub async fn reason_config(pool: &PgPool) -> ReasonConfig {
    let stored = load_all(pool).await.unwrap_or_default();
    reason_config_from(ReasonConfig::from_env(), &stored)
}

#[derive(Clone)]
pub struct ConnectorHandle {
    github: Arc<RwLock<crate::github::GithubConnector>>,
    notion: Arc<RwLock<crate::notion::NotionConnector>>,
}

impl ConnectorHandle {
    pub fn new(tokens: ConnectorTokens) -> Self {
        Self {
            github: Arc::new(RwLock::new(crate::github::GithubConnector::with_token(
                &tokens.github,
            ))),
            notion: Arc::new(RwLock::new(crate::notion::NotionConnector::with_token(
                &tokens.notion,
            ))),
        }
    }

    pub async fn github(&self) -> crate::github::GithubConnector {
        self.github.read().await.clone()
    }

    pub async fn notion(&self) -> crate::notion::NotionConnector {
        self.notion.read().await.clone()
    }

    pub async fn replace(&self, tokens: ConnectorTokens) {
        *self.github.write().await = crate::github::GithubConnector::with_token(&tokens.github);
        *self.notion.write().await = crate::notion::NotionConnector::with_token(&tokens.notion);
    }
}

#[derive(Clone)]
pub struct ReasonHandle {
    inner: Arc<RwLock<ReasonClient>>,
}

impl ReasonHandle {
    pub fn new(client: ReasonClient) -> Self {
        Self {
            inner: Arc::new(RwLock::new(client)),
        }
    }

    pub async fn current(&self) -> ReasonClient {
        self.inner.read().await.clone()
    }

    pub async fn replace(&self, client: ReasonClient) {
        *self.inner.write().await = client;
    }
}

#[cfg(test)]
mod tests {
    use super::{
        ConnectorTokens, GITHUB_TOKEN, REASON_API_KEY, REASON_MODEL, connector_tokens_from, hint,
        reason_config_from,
    };
    use crate::reason::ReasonConfig;
    use std::collections::HashMap;

    #[test]
    fn stored_values_override_env() {
        let env = ReasonConfig {
            provider: "openai".to_owned(),
            url: "http://ollama:11434/v1".to_owned(),
            model: "qwen3:1.7b".to_owned(),
            api_key: String::new(),
        };
        let mut stored = HashMap::new();
        stored.insert(REASON_API_KEY.to_owned(), "sk-live".to_owned());
        stored.insert(REASON_MODEL.to_owned(), "claude-sonnet-5".to_owned());
        let merged = reason_config_from(env, &stored);
        assert_eq!(merged.provider, "openai");
        assert_eq!(merged.model, "claude-sonnet-5");
        assert_eq!(merged.api_key, "sk-live");
    }

    #[test]
    fn a_stored_connector_token_beats_the_environment() {
        let env = ConnectorTokens {
            github: "gho_from_env".to_owned(),
            notion: String::new(),
        };
        let mut stored = HashMap::new();
        stored.insert(GITHUB_TOKEN.to_owned(), "gho_from_settings".to_owned());
        let merged = connector_tokens_from(env, &stored);
        assert_eq!(merged.github, "gho_from_settings");
        assert!(merged.notion.is_empty());
    }

    #[test]
    fn a_blank_stored_value_does_not_mask_the_environment() {
        let env = ReasonConfig {
            provider: "anthropic".to_owned(),
            url: String::new(),
            model: "claude-sonnet-5".to_owned(),
            api_key: "sk-env".to_owned(),
        };
        let mut stored = HashMap::new();
        stored.insert(REASON_API_KEY.to_owned(), String::new());
        stored.insert(REASON_MODEL.to_owned(), String::new());
        let merged = reason_config_from(env, &stored);
        assert_eq!(merged.api_key, "sk-env");
        assert_eq!(merged.model, "claude-sonnet-5");
    }

    #[test]
    fn a_hint_never_returns_the_token() {
        assert_eq!(hint("secret-abcd"), Some("set, ending abcd".to_owned()));
        assert_eq!(hint("   "), None);
    }

    #[test]
    fn env_survives_when_nothing_is_stored() {
        let env = ReasonConfig {
            provider: String::new(),
            url: String::new(),
            model: String::new(),
            api_key: "sk-env".to_owned(),
        };
        let merged = reason_config_from(env, &HashMap::new());
        assert_eq!(merged.api_key, "sk-env");
    }
}
