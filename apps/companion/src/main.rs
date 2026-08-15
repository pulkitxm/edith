mod ask;
mod baseline;
mod chat;
mod chunker;
mod claims;
mod commitments;
mod connectors;
mod core_memory;
mod council;
mod curate;
mod doctor;
mod embed;
mod entities;
mod evals;
mod facts;
mod friend;
mod frontmatter;
mod github;
mod grounding;
mod hypotheses;
mod indexer;
mod ingest;
mod inquire;
mod lang;
mod lenses;
mod machines;
mod media;
mod migrate;
mod nightly;
mod notion;
mod persona;
mod reason;
mod reflect;
mod rerank;
mod retrieve;
mod server;
mod settings;
mod signals;
mod standup;
mod stt;
mod turns;
mod vault;
mod vision;

use std::env;

use sqlx::postgres::PgPoolOptions;

use crate::embed::EmbedClient;

use crate::grounding::GroundingClient;
use crate::nightly::{NightlyDeps, spawn_scheduler};
use crate::reason::ReasonClient;
use crate::rerank::RerankClient;
use crate::server::AppState;
use crate::settings::{ConnectorHandle, ReasonHandle};
use crate::lang::SttRouter;
use crate::vision::VisionClient;
use crate::stt::SttClient;

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let database_url = env::var("DATABASE_URL").unwrap_or_else(|_| {
        "postgres://companion:companion-dev@127.0.0.1:5432/companion".to_owned()
    });
    let redis_url = env::var("REDIS_URL").unwrap_or_else(|_| "redis://127.0.0.1:6379".to_owned());
    let vault_dir = env::var("VAULT_DIR").unwrap_or_else(|_| "/vault".to_owned());

    let pool = PgPoolOptions::new().connect(&database_url).await?;
    migrate::run_migrations(&pool).await?;
    if env::args().any(|argument| argument == "--migrate-only") {
        println!("{} migrations applied", migrate::migration_count());
        return Ok(());
    }
    let redis = redis::Client::open(redis_url)?;
    let reason_config = settings::reason_config(&pool).await;
    let connector_tokens = settings::connector_tokens(&pool).await;
    let state = AppState {
        pool,
        redis,
        vault_dir: vault_dir.into(),
        embed: EmbedClient::from_env(),
        stt: SttRouter::from_env(SttClient::from_env()),
        vision: VisionClient::from_env(),
        connectors: ConnectorHandle::new(connector_tokens),
        rerank: RerankClient::from_env(),
        grounding: GroundingClient::from_env(),
        reason: ReasonHandle::new(ReasonClient::from_config(reason_config)),
    };
    spawn_scheduler(NightlyDeps {
        pool: state.pool.clone(),
        embed: state.embed.clone(),
        reason: state.reason.clone(),
        connectors: state.connectors.clone(),
        vault_dir: state.vault_dir.to_string_lossy().into_owned(),
    });
    let listener = tokio::net::TcpListener::bind("0.0.0.0:4820").await?;

    println!("companion api listening on 0.0.0.0:4820");
    axum::serve(listener, server::router(state)).await?;

    Ok(())
}
