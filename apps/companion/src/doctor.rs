use std::path::Path;

use redis::Client;
use serde::Serialize;
use sqlx::PgPool;
use tokio::fs::{self, OpenOptions};
use tokio::io::AsyncWriteExt;
use uuid::Uuid;

use crate::embed::EmbedClient;
use crate::migrate::migration_count;
use crate::notion::NotionConnector;
use crate::persona;
use crate::reason::ReasonClient;
use crate::rerank::RerankClient;
use crate::grounding::GroundingClient;
use crate::media::tooling_check;
use crate::vision::VisionClient;
use crate::lang::SttRouter;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Severity {
    Blocker,
    Degraded,
    Optional,
}

#[derive(Debug, Serialize)]
pub struct Check {
    pub name: &'static str,
    pub ok: bool,
    pub severity: Severity,
    pub detail: String,
}

#[derive(Debug, Serialize)]
pub struct DoctorResult {
    pub ok: bool,
    pub degraded: bool,
    pub checks: Vec<Check>,
}

impl DoctorResult {
    pub fn from_checks(checks: Vec<Check>) -> Self {
        let ok = checks
            .iter()
            .all(|item| item.ok || item.severity != Severity::Blocker);
        let degraded = checks.iter().any(|item| !item.ok);
        Self {
            ok,
            degraded,
            checks,
        }
    }
}

fn check(name: &'static str, severity: Severity, result: Result<String, String>) -> Check {
    match result {
        Ok(detail) => Check {
            name,
            ok: true,
            severity,
            detail,
        },
        Err(detail) => Check {
            name,
            ok: false,
            severity,
            detail,
        },
    }
}

async fn postgres_check(pool: &PgPool) -> Result<String, String> {
    sqlx::query("SELECT 1")
        .execute(pool)
        .await
        .map(|_| "connected".to_owned())
        .map_err(|error| error.to_string())
}

async fn migrations_check(pool: &PgPool) -> Result<String, String> {
    let applied = sqlx::query_scalar::<_, i64>("SELECT count(*) FROM schema_migrations")
        .fetch_one(pool)
        .await
        .map_err(|error| error.to_string())?;
    let detail = format!("{applied} of {} migrations applied", migration_count());
    if applied == migration_count() as i64 {
        Ok(detail)
    } else {
        Err(detail)
    }
}

async fn pgvector_check(pool: &PgPool) -> Result<String, String> {
    let installed = sqlx::query_scalar::<_, bool>(
        "SELECT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'vector')",
    )
    .fetch_one(pool)
    .await
    .map_err(|error| error.to_string())?;
    if installed {
        Ok("installed".to_owned())
    } else {
        Err("vector extension is not installed".to_owned())
    }
}

async fn redis_check(redis: &Client) -> Result<String, String> {
    let mut connection = redis
        .get_multiplexed_async_connection()
        .await
        .map_err(|error| error.to_string())?;
    let response = redis::cmd("PING")
        .query_async::<String>(&mut connection)
        .await
        .map_err(|error| error.to_string())?;
    if response == "PONG" {
        Ok("connected".to_owned())
    } else {
        Err(format!("unexpected response: {response}"))
    }
}

async fn vault_check(vault_dir: &Path) -> Result<String, String> {
    fs::create_dir_all(vault_dir)
        .await
        .map_err(|error| error.to_string())?;
    let path = vault_dir.join(format!(".doctor-{}", Uuid::new_v4()));
    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&path)
        .await
        .map_err(|error| error.to_string())?;
    if let Err(error) = file.write_all(b"ok").await {
        drop(file);
        let _ = fs::remove_file(&path).await;
        return Err(error.to_string());
    }
    drop(file);
    fs::remove_file(path)
        .await
        .map_err(|error| error.to_string())?;
    Ok("writable".to_owned())
}

async fn embeddings_check(embed: &EmbedClient) -> Result<String, String> {
    embed
        .version_probe()
        .await
        .map(|version| format!("ollama {version}, model {}", embed.model()))
        .map_err(|error| error.to_string())
}

async fn stt_check(stt: &SttRouter) -> Result<String, String> {
    stt.fast().probe().await.map_err(|error| error.to_string())?;
    if stt.split() {
        stt.quality()
            .probe()
            .await
            .map_err(|error| format!("hindi path: {error}"))?;
    }
    Ok(stt.describe())
}

pub struct DoctorDeps<'a> {
    pub pool: &'a PgPool,
    pub redis: &'a Client,
    pub vault_dir: &'a Path,
    pub embed: &'a EmbedClient,
    pub stt: &'a SttRouter,
    pub reason: &'a ReasonClient,
    pub rerank: &'a RerankClient,
    pub grounding: &'a GroundingClient,
    pub vision: &'a VisionClient,
    pub notion: &'a NotionConnector,
    pub github: &'a crate::github::GithubConnector,
}

pub async fn run_doctor(deps: DoctorDeps<'_>) -> DoctorResult {
    let DoctorDeps {
        pool,
        redis,
        vault_dir,
        embed,
        stt,
        reason,
        rerank,
        grounding,
        vision,
        notion,
        github,
    } = deps;
    let personas = persona::all();
    let checks = vec![
        check("postgres", Severity::Blocker, postgres_check(pool).await),
        check("migrations", Severity::Blocker, migrations_check(pool).await),
        check("pgvector", Severity::Blocker, pgvector_check(pool).await),
        check("redis", Severity::Optional, redis_check(redis).await),
        check("vault", Severity::Blocker, vault_check(vault_dir).await),
        check("embeddings", Severity::Blocker, embeddings_check(embed).await),
        check("stt", Severity::Degraded, stt_check(stt).await),
        check("reasoning", Severity::Blocker, configured_check(reason.describe(), reason.configured(), "no reasoning provider; set one from the app or `ed companion reason set`")),
        check("reranker", Severity::Optional, configured_check(rerank.describe(), rerank.configured(), "not configured, fusion order kept")),
        check("grounding", Severity::Optional, configured_check(grounding.describe(), grounding.configured(), "lexical overlap, no scorer configured")),
        check(
            "vision",
            Severity::Degraded,
            vision.probe().await.map_err(|error| error.to_string()),
        ),
        check("notion", Severity::Optional, configured_check(notion.describe(), notion.configured(), "no token; set it from the app or `ed companion connectors set`")),
        check("github", Severity::Optional, configured_check(github.describe(), github.configured(), "no token; set it from the app or `ed companion connectors set`")),
        check("media tooling", Severity::Degraded, tooling_check().await),
        check(
            "personas",
            Severity::Blocker,
            if personas.is_empty() {
                Err("no persona specs loaded".to_owned())
            } else {
                Ok(personas
                    .iter()
                    .map(|persona| persona.id.clone())
                    .collect::<Vec<_>>()
                    .join(", "))
            },
        ),
    ];
    DoctorResult::from_checks(checks)
}

fn configured_check(detail: String, configured: bool, unconfigured: &str) -> Result<String, String> {
    if configured {
        Ok(detail)
    } else {
        Err(unconfigured.to_owned())
    }
}

#[cfg(test)]
mod tests {
    use super::{Check, DoctorResult, Severity, check, configured_check};

    fn passing(name: &'static str, severity: Severity) -> Check {
        check(name, severity, Ok("fine".to_owned()))
    }

    fn failing(name: &'static str, severity: Severity) -> Check {
        check(name, severity, Err("broken".to_owned()))
    }

    #[test]
    fn an_optional_check_failing_does_not_make_the_companion_unhealthy() {
        let result = DoctorResult::from_checks(vec![
            passing("postgres", Severity::Blocker),
            failing("reranker", Severity::Optional),
        ]);
        assert!(result.ok);
        assert!(result.degraded);
    }

    #[test]
    fn a_blocker_failing_makes_the_companion_unhealthy() {
        let result = DoctorResult::from_checks(vec![
            passing("postgres", Severity::Blocker),
            failing("reasoning", Severity::Blocker),
        ]);
        assert!(!result.ok);
        assert!(result.degraded);
    }

    #[test]
    fn everything_passing_is_neither_unhealthy_nor_degraded() {
        let result = DoctorResult::from_checks(vec![
            passing("postgres", Severity::Blocker),
            passing("reranker", Severity::Optional),
        ]);
        assert!(result.ok);
        assert!(!result.degraded);
    }

    #[test]
    fn an_unconfigured_dependency_reports_not_ok_rather_than_a_cheerful_sentence() {
        let configured = configured_check("anthropic".to_owned(), true, "no provider");
        assert_eq!(configured, Ok("anthropic".to_owned()));
        let missing = configured_check("not configured".to_owned(), false, "no provider");
        assert_eq!(missing, Err("no provider".to_owned()));
    }

    #[test]
    fn severity_serialises_lowercase_for_the_wire() {
        let json = serde_json::to_string(&passing("postgres", Severity::Blocker)).unwrap();
        assert!(json.contains("\"severity\":\"blocker\""), "{json}");
    }
}
