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

#[derive(Debug, Serialize)]
pub struct Check {
    pub name: &'static str,
    pub ok: bool,
    pub detail: String,
}

#[derive(Debug, Serialize)]
pub struct DoctorResult {
    pub ok: bool,
    pub checks: Vec<Check>,
}

fn check(name: &'static str, result: Result<String, String>) -> Check {
    match result {
        Ok(detail) => Check {
            name,
            ok: true,
            detail,
        },
        Err(detail) => Check {
            name,
            ok: false,
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
        check("postgres", postgres_check(pool).await),
        check("migrations", migrations_check(pool).await),
        check("pgvector", pgvector_check(pool).await),
        check("redis", redis_check(redis).await),
        check("vault", vault_check(vault_dir).await),
        check("embeddings", embeddings_check(embed).await),
        check("stt", stt_check(stt).await),
        check("reasoning", Ok(reason.describe())),
        check("reranker", Ok(rerank.describe())),
        check("grounding", Ok(grounding.describe())),
        check(
            "vision",
            vision.probe().await.map_err(|error| error.to_string()),
        ),
        check("notion", Ok(notion.describe())),
        check("github", Ok(github.describe())),
        check("media tooling", tooling_check().await),
        check(
            "personas",
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
    DoctorResult {
        ok: checks.iter().all(|item| item.ok),
        checks,
    }
}
