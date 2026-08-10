use std::collections::HashMap;
use std::convert::Infallible;
use std::path::PathBuf;

use axum::body::to_bytes;
use axum::extract::{Path, Query, Request, State};
use axum::http::StatusCode;
use axum::response::sse::{Event as SseEvent, KeepAlive, Sse};
use axum::response::{IntoResponse, Response};
use axum::routing::{get, post};
use axum::{Json, Router};
use base64::Engine;
use chrono::{DateTime, SecondsFormat, Utc};
use futures_util::StreamExt;
use futures_util::stream;
use redis::Client;
use serde::Serialize;
use serde_json::{Value, json};
use sqlx::PgPool;
use tokio::sync::mpsc;
use uuid::Uuid;

use crate::ask::ask_run;
use crate::chat::{ChatDeps, chat_stream, event_json, resolve_conversation};
use crate::council::council_run;
use crate::claims::{corroborate_claims, extract_claims};
use crate::doctor::{DoctorDeps, run_doctor};
use crate::embed::EmbedClient;

use crate::grounding::GroundingClient;
use crate::friend::FriendDeps;
use crate::indexer::index_pending;
use crate::ingest::{IngestFile, ingest_audio, ingest_files, ingest_pdf, parse_file_date};
use crate::nightly::{NightlyDeps, record_run};
use crate::reason::ReasonClient;
use crate::persona;
use crate::reflect::reflect_run;
use crate::rerank::RerankClient;
use crate::retrieve::{RetrievalPolicy, retrieve};
use crate::settings::{self, ConnectorHandle, ReasonHandle};
use crate::lang::SttRouter;
use crate::media::{VideoDeps, ingest_image, ingest_video, kind_for};
use crate::vision::VisionClient;
use crate::turns::{RetrievedChunk, latency_since, log_turn};
use crate::{
    baseline, commitments, connectors, core_memory, curate, entities, evals, facts, hypotheses,
    inquire, lenses, machines, standup,
};

#[derive(Clone)]
pub struct AppState {
    pub pool: PgPool,
    pub redis: Client,
    pub vault_dir: PathBuf,
    pub embed: EmbedClient,
    pub stt: SttRouter,
    pub vision: VisionClient,
    pub connectors: ConnectorHandle,
    pub rerank: RerankClient,
    pub grounding: GroundingClient,
    pub reason: ReasonHandle,
}

#[derive(Serialize)]
struct StatusResult {
    sources: i64,
    episodes: i64,
    claims: i64,
    observations: i64,
    chunks: i64,
    pending_episodes: i64,
    latest_ingested_at: Option<String>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct SearchResult {
    chunk_id: Uuid,
    episode_id: Uuid,
    ord: i32,
    title: String,
    occurred_at: String,
    kind: String,
    snippet: String,
    score: f64,
}

#[derive(Serialize)]
struct EpisodeResult {
    id: Uuid,
    occurred_at: String,
    kind: String,
    title: String,
    sha256: String,
}

fn date_string(date: DateTime<Utc>) -> String {
    date.to_rfc3339_opts(SecondsFormat::AutoSi, true)
}

fn error_response(status: StatusCode, detail: impl ToString) -> Response {
    (status, Json(json!({ "error": detail.to_string() }))).into_response()
}

async fn health(State(state): State<AppState>) -> Response {
    let reason = state.reason.current().await;
    let notion = state.connectors.notion().await;
    let github = state.connectors.github().await;
    let result = run_doctor(DoctorDeps {
        pool: &state.pool,
        redis: &state.redis,
        vault_dir: &state.vault_dir,
        embed: &state.embed,
        stt: &state.stt,
        reason: &reason,
        rerank: &state.rerank,
        grounding: &state.grounding,
        vision: &state.vision,
        notion: &notion,
        github: &github,
    })
    .await;
    let status = if result.ok {
        StatusCode::OK
    } else {
        StatusCode::SERVICE_UNAVAILABLE
    };
    (status, Json(result)).into_response()
}

fn parse_files(body: Value) -> Result<Vec<IngestFile>, &'static str> {
    let object = body.as_object().ok_or("Body must be an object")?;
    let values = object
        .get("files")
        .and_then(Value::as_array)
        .ok_or("files must be an array")?;
    if values.len() > 200 {
        return Err("files must contain at most 200 items");
    }

    let mut files = Vec::with_capacity(values.len());
    for value in values {
        let Some(file) = value.as_object() else {
            return Err("Each file requires name and text");
        };
        let Some(name) = file.get("name").and_then(Value::as_str) else {
            return Err("Each file requires name and text");
        };
        let Some(text) = file.get("text").and_then(Value::as_str) else {
            return Err("Each file requires name and text");
        };
        if name.is_empty() {
            return Err("Each file requires name and text");
        }
        let mtime = match file.get("mtime") {
            None => None,
            Some(value) => {
                let Some(value) = value.as_str() else {
                    return Err("Each file requires name and text");
                };
                if parse_file_date(value).is_none() {
                    return Err("Each file requires name and text");
                }
                Some(value.to_owned())
            }
        };
        files.push(IngestFile {
            name: name.to_owned(),
            text: text.to_owned(),
            mtime,
        });
    }

    if files.iter().any(|file| file.text.len() > 2 * 1024 * 1024) {
        return Err("Each file must be at most 2MB");
    }

    Ok(files)
}

async fn ingest(State(state): State<AppState>, request: Request) -> Response {
    let bytes = match to_bytes(request.into_body(), 420 * 1024 * 1024).await {
        Ok(bytes) => bytes,
        Err(_) => return error_response(StatusCode::BAD_REQUEST, "Invalid JSON body"),
    };
    let body = match serde_json::from_slice::<Value>(&bytes) {
        Ok(body) => body,
        Err(_) => return error_response(StatusCode::BAD_REQUEST, "Invalid JSON body"),
    };
    let files = match parse_files(body) {
        Ok(files) => files,
        Err(error) => return error_response(StatusCode::BAD_REQUEST, error),
    };

    match ingest_files(&state.pool, &state.vault_dir, files).await {
        Ok(results) => {
            if results.iter().any(|result| result.status == "ingested") {
                spawn_index(&state);
            }
            Json(results).into_response()
        }
        Err(error) => error_response(StatusCode::INTERNAL_SERVER_ERROR, error),
    }
}

fn spawn_index(state: &AppState) {
    let pool = state.pool.clone();
    let embed = state.embed.clone();
    tokio::spawn(async move {
        if let Err(error) = index_pending(&pool, &embed).await {
            eprintln!("background indexing failed: {error}");
        }
    });
}

async fn ingest_audio_route(State(state): State<AppState>, request: Request) -> Response {
    let bytes = match to_bytes(request.into_body(), 64 * 1024 * 1024).await {
        Ok(bytes) => bytes,
        Err(_) => return error_response(StatusCode::BAD_REQUEST, "Invalid JSON body"),
    };
    let body = match serde_json::from_slice::<Value>(&bytes) {
        Ok(body) => body,
        Err(_) => return error_response(StatusCode::BAD_REQUEST, "Invalid JSON body"),
    };
    let Some(object) = body.as_object() else {
        return error_response(StatusCode::BAD_REQUEST, "Body must be an object");
    };
    let Some(name) = object
        .get("name")
        .and_then(Value::as_str)
        .filter(|value| !value.is_empty())
    else {
        return error_response(StatusCode::BAD_REQUEST, "name is required");
    };
    let Some(data) = object.get("dataB64").and_then(Value::as_str) else {
        return error_response(StatusCode::BAD_REQUEST, "dataB64 is required");
    };
    let mtime = match object.get("mtime") {
        None => None,
        Some(value) => match value
            .as_str()
            .filter(|value| parse_file_date(value).is_some())
        {
            Some(value) => Some(value.to_owned()),
            None => return error_response(StatusCode::BAD_REQUEST, "mtime must be a date"),
        },
    };
    let audio = match base64::engine::general_purpose::STANDARD.decode(data) {
        Ok(audio) if !audio.is_empty() => audio,
        Ok(_) => return error_response(StatusCode::BAD_REQUEST, "dataB64 is empty"),
        Err(_) => return error_response(StatusCode::BAD_REQUEST, "dataB64 is not valid base64"),
    };
    if audio.len() > 48 * 1024 * 1024 {
        return error_response(StatusCode::BAD_REQUEST, "Audio must be at most 48MB");
    }

    let reason = state.reason.current().await;
    match ingest_audio(
        &state.pool,
        &state.vault_dir,
        &state.stt,
        &reason,
        name.to_owned(),
        audio,
        mtime,
    )
    .await
    {
        Ok(outcome) => {
            if outcome.status == "ingested" {
                spawn_index(&state);
            }
            Json(outcome).into_response()
        }
        Err(error) => error_response(StatusCode::BAD_GATEWAY, error),
    }
}

async fn ask(State(state): State<AppState>, request: Request) -> Response {
    let reason = state.reason.current().await;
    if !reason.configured() {
        return error_response(
            StatusCode::PRECONDITION_FAILED,
            "no reasoning provider is configured on the companion",
        );
    }
    let bytes = match to_bytes(request.into_body(), 1024 * 1024).await {
        Ok(bytes) => bytes,
        Err(_) => return error_response(StatusCode::BAD_REQUEST, "Invalid JSON body"),
    };
    let question = serde_json::from_slice::<Value>(&bytes)
        .ok()
        .and_then(|body| {
            body.get("question")
                .and_then(Value::as_str)
                .map(str::trim)
                .filter(|question| !question.is_empty())
                .map(str::to_owned)
        });
    let Some(question) = question else {
        return error_response(StatusCode::BAD_REQUEST, "question is required");
    };
    let persona_id = serde_json::from_slice::<Value>(&bytes)
        .ok()
        .and_then(|body| {
            body.get("persona")
                .and_then(Value::as_str)
                .map(str::trim)
                .filter(|value| !value.is_empty())
                .map(str::to_owned)
        });
    let deps = FriendDeps {
        pool: &state.pool,
        embed: &state.embed,
        rerank: &state.rerank,
        grounding: &state.grounding,
        reason: &reason,
    };
    match ask_run(&deps, &question, persona_id.as_deref()).await {
        Ok(outcome) => Json(outcome).into_response(),
        Err(error) => error_response(StatusCode::BAD_GATEWAY, error),
    }
}

async fn personas(State(_state): State<AppState>) -> Response {
    Json(persona::all()).into_response()
}

async fn council(State(state): State<AppState>, request: Request) -> Response {
    let reason = state.reason.current().await;
    if !reason.configured() {
        return error_response(
            StatusCode::PRECONDITION_FAILED,
            "no reasoning provider is configured on the companion",
        );
    }
    let bytes = match to_bytes(request.into_body(), 1024 * 1024).await {
        Ok(bytes) => bytes,
        Err(_) => return error_response(StatusCode::BAD_REQUEST, "Invalid JSON body"),
    };
    let body = serde_json::from_slice::<Value>(&bytes).unwrap_or(Value::Null);
    let Some(question) = body
        .get("question")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|question| !question.is_empty())
    else {
        return error_response(StatusCode::BAD_REQUEST, "question is required");
    };
    let requested = body
        .get("personas")
        .and_then(Value::as_array)
        .map(|values| {
            values
                .iter()
                .filter_map(Value::as_str)
                .map(str::to_owned)
                .collect::<Vec<_>>()
        })
        .unwrap_or_default();
    let deps = FriendDeps {
        pool: &state.pool,
        embed: &state.embed,
        rerank: &state.rerank,
        grounding: &state.grounding,
        reason: &reason,
    };
    match council_run(&deps, question, &requested).await {
        Ok(outcome) => Json(outcome).into_response(),
        Err(error) => error_response(StatusCode::BAD_GATEWAY, error),
    }
}

async fn core_memory_route(State(state): State<AppState>) -> Response {
    match core_memory::load(&state.pool).await {
        Ok(sections) => Json(sections).into_response(),
        Err(error) => error_response(StatusCode::INTERNAL_SERVER_ERROR, error),
    }
}

async fn core_memory_write(State(state): State<AppState>, request: Request) -> Response {
    let bytes = match to_bytes(request.into_body(), 256 * 1024).await {
        Ok(bytes) => bytes,
        Err(_) => return error_response(StatusCode::BAD_REQUEST, "Invalid JSON body"),
    };
    let body = serde_json::from_slice::<Value>(&bytes).unwrap_or(Value::Null);
    let section = body.get("section").and_then(Value::as_str).unwrap_or("");
    let content = body.get("content").and_then(Value::as_str).unwrap_or("");
    if !core_memory::SECTIONS.contains(&section) {
        return error_response(StatusCode::BAD_REQUEST, "unknown core memory section");
    }
    match core_memory::put(&state.pool, section, content.trim(), "user").await {
        Ok(()) => Json(serde_json::json!({"section": section, "ok": true})).into_response(),
        Err(error) => error_response(StatusCode::INTERNAL_SERVER_ERROR, error),
    }
}

fn limit_of(query: &HashMap<String, String>, fallback: i64) -> i64 {
    query
        .get("limit")
        .and_then(|value| value.trim().parse::<i64>().ok())
        .unwrap_or(fallback)
        .clamp(1, 500)
}

async fn hypotheses_route(
    State(state): State<AppState>,
    Query(query): Query<HashMap<String, String>>,
) -> Response {
    match hypotheses::list(&state.pool, limit_of(&query, 30)).await {
        Ok(rows) => Json(rows).into_response(),
        Err(error) => error_response(StatusCode::INTERNAL_SERVER_ERROR, error),
    }
}

async fn hypotheses_run(State(state): State<AppState>) -> Response {
    let reason = state.reason.current().await;
    let resolved = hypotheses::resolve_due(&state.pool, &reason).await;
    let formed = hypotheses::generate(&state.pool, &state.embed, &reason).await;
    match (resolved, formed) {
        (Ok(resolved), Ok(formed)) => Json(serde_json::json!({
            "resolved": resolved,
            "generated": formed,
        }))
        .into_response(),
        (Err(error), _) | (_, Err(error)) => error_response(StatusCode::BAD_GATEWAY, error),
    }
}

async fn predictions_route(
    State(state): State<AppState>,
    Query(query): Query<HashMap<String, String>>,
) -> Response {
    type Row = (
        Uuid,
        Uuid,
        String,
        String,
        DateTime<Utc>,
        DateTime<Utc>,
        Option<DateTime<Utc>>,
        Option<String>,
    );
    let rows = sqlx::query_as::<_, Row>(
        "SELECT p.id, p.hypothesis_id, p.statement, p.observable, p.window_start, p.window_end, p.resolved_at, p.outcome FROM predictions p ORDER BY p.window_end DESC LIMIT $1",
    )
    .bind(limit_of(&query, 40))
    .fetch_all(&state.pool)
    .await;
    match rows {
        Ok(rows) => Json(
            rows.into_iter()
                .map(|row| {
                    serde_json::json!({
                        "id": row.0,
                        "hypothesisId": row.1,
                        "statement": row.2,
                        "observable": row.3,
                        "windowStart": date_string(row.4),
                        "windowEnd": date_string(row.5),
                        "resolvedAt": row.6.map(date_string),
                        "outcome": row.7,
                    })
                })
                .collect::<Vec<_>>(),
        )
        .into_response(),
        Err(error) => error_response(StatusCode::INTERNAL_SERVER_ERROR, error),
    }
}

async fn commitments_route(
    State(state): State<AppState>,
    Query(query): Query<HashMap<String, String>>,
) -> Response {
    match commitments::commitments(&state.pool, limit_of(&query, 30)).await {
        Ok(rows) => Json(rows).into_response(),
        Err(error) => error_response(StatusCode::INTERNAL_SERVER_ERROR, error),
    }
}

async fn discrepancies_route(
    State(state): State<AppState>,
    Query(query): Query<HashMap<String, String>>,
) -> Response {
    match commitments::discrepancies(&state.pool, limit_of(&query, 30)).await {
        Ok(rows) => Json(rows).into_response(),
        Err(error) => error_response(StatusCode::INTERNAL_SERVER_ERROR, error),
    }
}

async fn discrepancy_override(
    State(state): State<AppState>,
    Path(id): Path<Uuid>,
    request: Request,
) -> Response {
    let bytes = match to_bytes(request.into_body(), 64 * 1024).await {
        Ok(bytes) => bytes,
        Err(_) => return error_response(StatusCode::BAD_REQUEST, "Invalid JSON body"),
    };
    let body = serde_json::from_slice::<Value>(&bytes).unwrap_or(Value::Null);
    let Some(real) = body
        .get("real")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|real| !real.is_empty())
    else {
        return error_response(StatusCode::BAD_REQUEST, "real is required");
    };
    match commitments::override_discrepancy(&state.pool, id, real).await {
        Ok(true) => Json(serde_json::json!({"id": id, "ok": true})).into_response(),
        Ok(false) => error_response(StatusCode::NOT_FOUND, "no such discrepancy"),
        Err(error) => error_response(StatusCode::INTERNAL_SERVER_ERROR, error),
    }
}

async fn calibration_route(State(state): State<AppState>) -> Response {
    match commitments::calibration_profile(&state.pool).await {
        Ok(rows) => Json(rows).into_response(),
        Err(error) => error_response(StatusCode::INTERNAL_SERVER_ERROR, error),
    }
}

async fn questions_route(
    State(state): State<AppState>,
    Query(query): Query<HashMap<String, String>>,
) -> Response {
    match inquire::list(&state.pool, limit_of(&query, 30)).await {
        Ok(rows) => {
            let muted = inquire::muted(&state.pool).await.unwrap_or_default();
            let asked = inquire::asked_today(&state.pool).await.unwrap_or(0);
            Json(serde_json::json!({
                "questions": rows,
                "muted": muted,
                "askedToday": asked,
                "dailyBudget": inquire::DAILY_BUDGET,
            }))
            .into_response()
        }
        Err(error) => error_response(StatusCode::INTERNAL_SERVER_ERROR, error),
    }
}

async fn question_next(State(state): State<AppState>) -> Response {
    if let Err(error) = inquire::seed_onboarding(&state.pool).await {
        return error_response(StatusCode::INTERNAL_SERVER_ERROR, error);
    }
    match inquire::next(&state.pool).await {
        Ok(Some(question)) => {
            if let Err(error) = inquire::mark_asked(&state.pool, question.id).await {
                return error_response(StatusCode::INTERNAL_SERVER_ERROR, error);
            }
            Json(serde_json::json!({"question": question})).into_response()
        }
        Ok(None) => Json(serde_json::json!({
            "question": Value::Null,
            "askedToday": inquire::asked_today(&state.pool).await.unwrap_or(0),
            "dailyBudget": inquire::DAILY_BUDGET,
        }))
        .into_response(),
        Err(error) => error_response(StatusCode::INTERNAL_SERVER_ERROR, error),
    }
}

async fn question_answer(
    State(state): State<AppState>,
    Path(id): Path<Uuid>,
    request: Request,
) -> Response {
    let bytes = match to_bytes(request.into_body(), 512 * 1024).await {
        Ok(bytes) => bytes,
        Err(_) => return error_response(StatusCode::BAD_REQUEST, "Invalid JSON body"),
    };
    let body = serde_json::from_slice::<Value>(&bytes).unwrap_or(Value::Null);
    let Some(text) = body
        .get("answer")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|text| !text.is_empty())
    else {
        return error_response(StatusCode::BAD_REQUEST, "answer is required");
    };
    match inquire::answer(&state.pool, id, text).await {
        Ok(outcome) => Json(outcome).into_response(),
        Err(error) if error.to_string() == "no such question" => {
            error_response(StatusCode::NOT_FOUND, error)
        }
        Err(error) => error_response(StatusCode::INTERNAL_SERVER_ERROR, error),
    }
}

async fn question_skip(State(state): State<AppState>, Path(id): Path<Uuid>) -> Response {
    match inquire::skip(&state.pool, id).await {
        Ok(true) => Json(serde_json::json!({"id": id, "status": "skipped"})).into_response(),
        Ok(false) => error_response(StatusCode::NOT_FOUND, "no such question"),
        Err(error) => error_response(StatusCode::INTERNAL_SERVER_ERROR, error),
    }
}

async fn question_mute(State(state): State<AppState>, request: Request) -> Response {
    let bytes = match to_bytes(request.into_body(), 64 * 1024).await {
        Ok(bytes) => bytes,
        Err(_) => return error_response(StatusCode::BAD_REQUEST, "Invalid JSON body"),
    };
    let body = serde_json::from_slice::<Value>(&bytes).unwrap_or(Value::Null);
    let Some(topic) = body
        .get("topic")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|topic| !topic.is_empty())
    else {
        return error_response(StatusCode::BAD_REQUEST, "topic is required");
    };
    match inquire::mute(&state.pool, &topic.to_lowercase()).await {
        Ok(suppressed) => {
            Json(serde_json::json!({"topic": topic, "suppressed": suppressed})).into_response()
        }
        Err(error) => error_response(StatusCode::INTERNAL_SERVER_ERROR, error),
    }
}

async fn entities_route(
    State(state): State<AppState>,
    Query(query): Query<HashMap<String, String>>,
) -> Response {
    if let Some(name) = query.get("name").map(|value| value.trim()).filter(|value| !value.is_empty())
    {
        return match entities::timeline(&state.pool, name, limit_of(&query, 40)).await {
            Ok(rows) => Json(serde_json::json!({"name": name, "timeline": rows})).into_response(),
            Err(error) => error_response(StatusCode::INTERNAL_SERVER_ERROR, error),
        };
    }
    match entities::list(&state.pool, limit_of(&query, 40)).await {
        Ok(rows) => Json(rows).into_response(),
        Err(error) => error_response(StatusCode::INTERNAL_SERVER_ERROR, error),
    }
}

async fn lenses_route(State(state): State<AppState>) -> Response {
    match lenses::list(&state.pool).await {
        Ok(rows) => Json(rows).into_response(),
        Err(error) => error_response(StatusCode::INTERNAL_SERVER_ERROR, error),
    }
}

async fn evals_route(
    State(state): State<AppState>,
    Query(query): Query<HashMap<String, String>>,
) -> Response {
    match evals::history(&state.pool, limit_of(&query, 20)).await {
        Ok(rows) => Json(rows).into_response(),
        Err(error) => error_response(StatusCode::INTERNAL_SERVER_ERROR, error),
    }
}

async fn evals_run(
    State(state): State<AppState>,
    Query(query): Query<HashMap<String, String>>,
) -> Response {
    let reason = state.reason.current().await;
    let deps = FriendDeps {
        pool: &state.pool,
        embed: &state.embed,
        rerank: &state.rerank,
        grounding: &state.grounding,
        reason: &reason,
    };
    match evals::run(&deps, query.get("persona").map(String::as_str)).await {
        Ok(outcome) => Json(outcome).into_response(),
        Err(error) => error_response(StatusCode::BAD_GATEWAY, error),
    }
}

async fn standup_route(State(state): State<AppState>, request: Request) -> Response {
    let bytes = match to_bytes(request.into_body(), 4 * 1024 * 1024).await {
        Ok(bytes) => bytes,
        Err(_) => return error_response(StatusCode::BAD_REQUEST, "Invalid JSON body"),
    };
    let body = serde_json::from_slice::<Value>(&bytes).unwrap_or(Value::Null);
    let Some(text) = body
        .get("text")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|text| !text.is_empty())
    else {
        return error_response(StatusCode::BAD_REQUEST, "text is required");
    };
    let verify = body
        .get("verify")
        .and_then(Value::as_bool)
        .unwrap_or(false);
    let reason = state.reason.current().await;
    match standup::record(&state.pool, &state.vault_dir, &reason, text, verify).await {
        Ok(outcome) => {
            spawn_index(&state);
            Json(outcome).into_response()
        }
        Err(error) => error_response(StatusCode::BAD_GATEWAY, error),
    }
}

async fn standup_aggregate(
    State(state): State<AppState>,
    Query(query): Query<HashMap<String, String>>,
) -> Response {
    let aggregate = standup::aggregate(&state.pool).await;
    let phrase = match query.get("phrase").map(String::as_str).filter(|phrase| !phrase.is_empty()) {
        Some(phrase) => standup::phrase_history(&state.pool, phrase).await.ok(),
        None => None,
    };
    match aggregate {
        Ok(aggregate) => Json(json!({
            "aggregate": aggregate,
            "phrase": phrase,
            "dueSoon": standup::due_soon(&state.pool).await.unwrap_or(0),
        }))
        .into_response(),
        Err(error) => error_response(StatusCode::INTERNAL_SERVER_ERROR, error),
    }
}

async fn machines_route(State(state): State<AppState>) -> Response {
    match machines::list(&state.pool).await {
        Ok(rows) => Json(rows).into_response(),
        Err(error) => error_response(StatusCode::INTERNAL_SERVER_ERROR, error),
    }
}

async fn machines_add(State(state): State<AppState>, request: Request) -> Response {
    let bytes = match to_bytes(request.into_body(), 64 * 1024).await {
        Ok(bytes) => bytes,
        Err(_) => return error_response(StatusCode::BAD_REQUEST, "Invalid JSON body"),
    };
    let body = serde_json::from_slice::<Value>(&bytes).unwrap_or(Value::Null);
    let Some(name) = body
        .get("name")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|name| !name.is_empty())
    else {
        return error_response(StatusCode::BAD_REQUEST, "name is required");
    };
    let transport = body
        .get("transport")
        .and_then(Value::as_str)
        .unwrap_or("local");
    if !["local", "ssh", "context"].contains(&transport) {
        return error_response(
            StatusCode::BAD_REQUEST,
            "transport must be local, ssh or context",
        );
    }
    let endpoint = body.get("endpoint").and_then(Value::as_str).unwrap_or("");
    match machines::add(&state.pool, name, transport, endpoint).await {
        Ok(id) => Json(json!({"id": id, "name": name, "transport": transport})).into_response(),
        Err(error) => error_response(StatusCode::INTERNAL_SERVER_ERROR, error),
    }
}

async fn machines_probe(State(state): State<AppState>, Path(name): Path<String>) -> Response {
    match machines::probe(&state.pool, &name).await {
        Ok(machine) => Json(machine).into_response(),
        Err(error) => error_response(StatusCode::BAD_GATEWAY, error),
    }
}

async fn machines_plan(State(state): State<AppState>) -> Response {
    match machines::plan(&state.pool).await {
        Ok(plan) => Json(plan).into_response(),
        Err(error) => error_response(StatusCode::INTERNAL_SERVER_ERROR, error),
    }
}

async fn machines_profile(
    State(state): State<AppState>,
    Path(name): Path<String>,
    request: Request,
) -> Response {
    let bytes = match to_bytes(request.into_body(), 16 * 1024).await {
        Ok(bytes) => bytes,
        Err(_) => return error_response(StatusCode::BAD_REQUEST, "Invalid JSON body"),
    };
    let body = serde_json::from_slice::<Value>(&bytes).unwrap_or(Value::Null);
    let Some(profile) = body
        .get("profile")
        .and_then(Value::as_str)
        .filter(|profile| {
            ["gpu-large", "gpu-small", "apple-metal", "cpu-only"].contains(profile)
        })
    else {
        return error_response(
            StatusCode::BAD_REQUEST,
            "profile must be gpu-large, gpu-small, apple-metal or cpu-only",
        );
    };
    match machines::set_profile(&state.pool, &name, profile).await {
        Ok(true) => Json(json!({"name": name, "profile": profile})).into_response(),
        Ok(false) => error_response(StatusCode::NOT_FOUND, "no such machine"),
        Err(error) => error_response(StatusCode::INTERNAL_SERVER_ERROR, error),
    }
}

async fn memory_why(State(state): State<AppState>, Path(id): Path<Uuid>) -> Response {
    type BeliefRow = (
        String,
        String,
        f32,
        f32,
        String,
        String,
        Vec<Uuid>,
        Vec<Uuid>,
        String,
        DateTime<Utc>,
        DateTime<Utc>,
        Option<Uuid>,
    );
    if let Ok(Some(belief)) = sqlx::query_as::<_, BeliefRow>(
        "SELECT statement, kind, confidence, stability, corroboration, status, evidence_episode_ids, counter_evidence_episode_ids, extractor_version, first_formed, last_confirmed, superseded_by FROM beliefs WHERE id = $1",
    )
    .bind(id)
    .fetch_optional(&state.pool)
    .await
    {
        let evidence = episode_titles(&state.pool, &belief.6).await;
        let counter = episode_titles(&state.pool, &belief.7).await;
        let links = sqlx::query_as::<_, (Uuid, String, String)>(
            "SELECT b.id, l.relation, b.statement FROM belief_links l JOIN beliefs b ON b.id = l.to_id WHERE l.from_id = $1",
        )
        .bind(id)
        .fetch_all(&state.pool)
        .await
        .unwrap_or_default();
        return Json(json!({
            "kind": "belief",
            "id": id,
            "statement": belief.0,
            "beliefKind": belief.1,
            "confidence": belief.2,
            "stability": belief.3,
            "corroboration": belief.4,
            "status": belief.5,
            "promptVersion": belief.8,
            "firstFormed": date_string(belief.9),
            "lastConfirmed": date_string(belief.10),
            "supersededBy": belief.11,
            "evidence": evidence,
            "counterEvidence": counter,
            "links": links.iter().map(|(to, relation, statement)| json!({
                "id": to, "relation": relation, "statement": statement,
            })).collect::<Vec<_>>(),
        }))
        .into_response();
    }

    type HypothesisRow = (
        String,
        String,
        String,
        f32,
        f32,
        i32,
        Vec<String>,
        DateTime<Utc>,
        String,
    );
    if let Ok(Some(row)) = sqlx::query_as::<_, HypothesisRow>(
        "SELECT statement, mechanism, status, prior, posterior, test_count, alternative_explanations, formed_at, generated_by FROM hypotheses WHERE id = $1",
    )
    .bind(id)
    .fetch_optional(&state.pool)
    .await
    {
        let revisions = sqlx::query_as::<_, (DateTime<Utc>, f32, String, String)>(
            "SELECT at, posterior, status, note FROM hypothesis_revisions WHERE hypothesis_id = $1 ORDER BY at",
        )
        .bind(id)
        .fetch_all(&state.pool)
        .await
        .unwrap_or_default();
        let predictions = sqlx::query_as::<_, (Uuid, String, String, Option<String>)>(
            "SELECT id, statement, observable, outcome FROM predictions WHERE hypothesis_id = $1 ORDER BY window_end",
        )
        .bind(id)
        .fetch_all(&state.pool)
        .await
        .unwrap_or_default();
        return Json(json!({
            "kind": "hypothesis",
            "id": id,
            "statement": row.0,
            "mechanism": row.1,
            "status": row.2,
            "prior": row.3,
            "posterior": row.4,
            "testCount": row.5,
            "alternatives": row.6,
            "formedAt": date_string(row.7),
            "generatedBy": row.8,
            "revisions": revisions.iter().map(|(at, posterior, status, note)| json!({
                "at": date_string(*at), "posterior": posterior, "status": status, "note": note,
            })).collect::<Vec<_>>(),
            "predictions": predictions.iter().map(|(id, statement, observable, outcome)| json!({
                "id": id, "statement": statement, "observable": observable, "outcome": outcome,
            })).collect::<Vec<_>>(),
        }))
        .into_response();
    }

    type ClaimRow = (Uuid, String, String, DateTime<Utc>, bool);
    if let Ok(Some(claim)) = sqlx::query_as::<_, ClaimRow>(
        "SELECT episode_id, statement, claim_type, asserted_at, testable FROM claims WHERE id = $1",
    )
    .bind(id)
    .fetch_optional(&state.pool)
    .await
    {
        let verdicts = sqlx::query_as::<_, (String, String, DateTime<Utc>)>(
            "SELECT verdict, note, checked_at FROM corroborations WHERE claim_id = $1 ORDER BY checked_at",
        )
        .bind(id)
        .fetch_all(&state.pool)
        .await
        .unwrap_or_default();
        return Json(json!({
            "kind": "claim",
            "id": id,
            "statement": claim.1,
            "claimType": claim.2,
            "assertedAt": date_string(claim.3),
            "testable": claim.4,
            "episode": episode_titles(&state.pool, &[claim.0]).await,
            "verdicts": verdicts.iter().map(|(verdict, note, at)| json!({
                "verdict": verdict, "note": note, "at": date_string(*at),
            })).collect::<Vec<_>>(),
        }))
        .into_response();
    }

    error_response(
        StatusCode::NOT_FOUND,
        "no belief, hypothesis or claim with that id",
    )
}

async fn episode_titles(pool: &PgPool, ids: &[Uuid]) -> Vec<Value> {
    if ids.is_empty() {
        return Vec::new();
    }
    sqlx::query_as::<_, (Uuid, DateTime<Utc>, String, String)>(
        "SELECT id, occurred_at, kind, left(body_original, 240) FROM episodes WHERE id = ANY($1) ORDER BY occurred_at",
    )
    .bind(ids)
    .fetch_all(pool)
    .await
    .unwrap_or_default()
    .into_iter()
    .map(|(id, occurred_at, kind, excerpt)| {
        json!({
            "episodeId": id,
            "occurredAt": date_string(occurred_at),
            "kind": kind,
            "excerpt": excerpt,
        })
    })
    .collect()
}

async fn connectors_show(State(state): State<AppState>) -> Response {
    let github = state.connectors.github().await;
    let notion = state.connectors.notion().await;
    Json(json!({
        "github": {"configured": github.configured(), "detail": github.describe()},
        "notion": {"configured": notion.configured(), "detail": notion.describe()},
        "sources": connectors::SOURCES,
        "importable": ["calendar", "music", "youtube"],
    }))
    .into_response()
}

async fn connectors_set(State(state): State<AppState>, request: Request) -> Response {
    let bytes = match to_bytes(request.into_body(), 64 * 1024).await {
        Ok(bytes) => bytes,
        Err(_) => return error_response(StatusCode::BAD_REQUEST, "Invalid JSON body"),
    };
    let body = serde_json::from_slice::<Value>(&bytes).unwrap_or(Value::Null);
    let mut touched = Vec::new();
    for (field, key) in [
        ("github", settings::GITHUB_TOKEN),
        ("notion", settings::NOTION_TOKEN),
    ] {
        let Some(token) = body.get(field).and_then(Value::as_str) else {
            continue;
        };
        let result = if token.trim().is_empty() {
            settings::remove(&state.pool, key).await
        } else {
            settings::put(&state.pool, key, token.trim()).await
        };
        if let Err(error) = result {
            return error_response(StatusCode::INTERNAL_SERVER_ERROR, error);
        }
        touched.push(field);
    }
    if touched.is_empty() {
        return error_response(
            StatusCode::BAD_REQUEST,
            "pass github or notion, empty to clear",
        );
    }
    let tokens = settings::connector_tokens(&state.pool).await;
    state.connectors.replace(tokens).await;
    connectors_show(State(state)).await
}

async fn connectors_import(
    State(state): State<AppState>,
    Path(source): Path<String>,
    request: Request,
) -> Response {
    let bytes = match to_bytes(request.into_body(), 64 * 1024 * 1024).await {
        Ok(bytes) => bytes,
        Err(_) => return error_response(StatusCode::BAD_REQUEST, "Invalid JSON body"),
    };
    let body = match serde_json::from_slice::<Value>(&bytes) {
        Ok(body) => body,
        Err(_) => return error_response(StatusCode::BAD_REQUEST, "Invalid JSON body"),
    };
    match connectors::import(&state.pool, &source, &body).await {
        Ok(outcome) => Json(outcome).into_response(),
        Err(error) => error_response(StatusCode::BAD_REQUEST, error),
    }
}

async fn usage_route(State(state): State<AppState>, request: Request) -> Response {
    let bytes = match to_bytes(request.into_body(), 256 * 1024).await {
        Ok(bytes) => bytes,
        Err(_) => return error_response(StatusCode::BAD_REQUEST, "Invalid JSON body"),
    };
    let body = serde_json::from_slice::<Value>(&bytes).unwrap_or(Value::Null);
    let Some(kind) = body
        .get("kind")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|kind| !kind.is_empty())
    else {
        return error_response(StatusCode::BAD_REQUEST, "kind is required");
    };
    let observed_at = body
        .get("observedAt")
        .and_then(Value::as_str)
        .and_then(crate::ingest::parse_file_date)
        .unwrap_or_else(Utc::now);
    let payload = body.get("payload").cloned().unwrap_or(json!({}));
    match connectors::record_usage(&state.pool, kind, &payload, observed_at).await {
        Ok(inserted) => Json(json!({"kind": kind, "inserted": inserted})).into_response(),
        Err(error) => error_response(StatusCode::INTERNAL_SERVER_ERROR, error),
    }
}

async fn facts_route(
    State(state): State<AppState>,
    Query(query): Query<HashMap<String, String>>,
) -> Response {
    let as_of = query
        .get("asOf")
        .and_then(|value| crate::ingest::parse_file_date(value));
    let timeline = query
        .get("timeline")
        .map(String::as_str)
        .unwrap_or("valid");
    match facts::list(&state.pool, as_of, timeline, limit_of(&query, 40)).await {
        Ok(rows) => Json(rows).into_response(),
        Err(error) => error_response(StatusCode::INTERNAL_SERVER_ERROR, error),
    }
}

async fn belief_correct(
    State(state): State<AppState>,
    Path(id): Path<Uuid>,
    request: Request,
) -> Response {
    let bytes = match to_bytes(request.into_body(), 64 * 1024).await {
        Ok(bytes) => bytes,
        Err(_) => return error_response(StatusCode::BAD_REQUEST, "Invalid JSON body"),
    };
    let body = serde_json::from_slice::<Value>(&bytes).unwrap_or(Value::Null);
    let retire = body.get("retire").and_then(Value::as_bool).unwrap_or(false);
    let edit = body.get("statement").and_then(Value::as_str);
    match curate::correct(&state.pool, &state.embed, id, retire, edit).await {
        Ok(outcome) => Json(outcome).into_response(),
        Err(error) if error.to_string() == "no such belief" => {
            error_response(StatusCode::NOT_FOUND, error)
        }
        Err(error) => error_response(StatusCode::BAD_REQUEST, error),
    }
}

async fn weekly_route(State(state): State<AppState>) -> Response {
    let reason = state.reason.current().await;
    match curate::weekly(&state.pool, &state.embed, &reason).await {
        Ok(outcome) => Json(outcome).into_response(),
        Err(error) => error_response(StatusCode::BAD_GATEWAY, error),
    }
}

async fn db_route(State(state): State<AppState>, Path(action): Path<String>) -> Response {
    match action.as_str() {
        "reindex" => match curate::reindex(&state.pool).await {
            Ok(dropped) => Json(json!({"chunksDropped": dropped})).into_response(),
            Err(error) => error_response(StatusCode::INTERNAL_SERVER_ERROR, error),
        },
        "rebuild-derived" => match curate::rebuild_derived(&state.pool).await {
            Ok(outcome) => Json(outcome).into_response(),
            Err(error) => error_response(StatusCode::INTERNAL_SERVER_ERROR, error),
        },
        "migrate" => match crate::migrate::run_migrations(&state.pool).await {
            Ok(()) => Json(json!({"ok": true})).into_response(),
            Err(error) => error_response(StatusCode::INTERNAL_SERVER_ERROR, error),
        },
        _ => error_response(
            StatusCode::BAD_REQUEST,
            "the actions are migrate, reindex and rebuild-derived",
        ),
    }
}

async fn feedback_route(
    State(state): State<AppState>,
    Path(id): Path<Uuid>,
    request: Request,
) -> Response {
    let bytes = match to_bytes(request.into_body(), 16 * 1024).await {
        Ok(bytes) => bytes,
        Err(_) => return error_response(StatusCode::BAD_REQUEST, "Invalid JSON body"),
    };
    let body = serde_json::from_slice::<Value>(&bytes).unwrap_or(Value::Null);
    let Some(rating) = body
        .get("rating")
        .and_then(Value::as_i64)
        .filter(|rating| (-1..=1).contains(rating))
    else {
        return error_response(StatusCode::BAD_REQUEST, "rating must be -1, 0 or 1");
    };
    let updated = sqlx::query("UPDATE retrievals SET feedback = $2 WHERE turn_id = $1")
        .bind(id)
        .bind(rating as i16)
        .execute(&state.pool)
        .await;
    match updated {
        Ok(updated) => Json(json!({
            "turnId": id,
            "rating": rating,
            "retrievals": updated.rows_affected(),
        }))
        .into_response(),
        Err(error) => error_response(StatusCode::INTERNAL_SERVER_ERROR, error),
    }
}

async fn baselines(State(state): State<AppState>) -> Response {
    match baseline::baselines(&state.pool).await {
        Ok(rows) => {
            let seconds = baseline::audio_seconds(&state.pool).await.unwrap_or(0.0);
            Json(serde_json::json!({
                "audioSeconds": seconds,
                "coldStart": seconds < baseline::COLD_START_SECONDS,
                "baselines": rows,
            }))
            .into_response()
        }
        Err(error) => error_response(StatusCode::INTERNAL_SERVER_ERROR, error),
    }
}

fn decoded_upload(body: &Value, cap: usize) -> Result<(String, Vec<u8>, Option<String>), String> {
    let Some(object) = body.as_object() else {
        return Err("Body must be an object".to_owned());
    };
    let Some(name) = object
        .get("name")
        .and_then(Value::as_str)
        .filter(|value| !value.is_empty())
    else {
        return Err("name is required".to_owned());
    };
    let Some(data) = object.get("dataB64").and_then(Value::as_str) else {
        return Err("dataB64 is required".to_owned());
    };
    let mtime = match object.get("mtime") {
        None | Some(Value::Null) => None,
        Some(value) => match value
            .as_str()
            .filter(|value| parse_file_date(value).is_some())
        {
            Some(value) => Some(value.to_owned()),
            None => return Err("mtime must be a date".to_owned()),
        },
    };
    let decoded = match base64::engine::general_purpose::STANDARD.decode(data) {
        Ok(decoded) if !decoded.is_empty() => decoded,
        Ok(_) => return Err("dataB64 is empty".to_owned()),
        Err(_) => return Err("dataB64 is not valid base64".to_owned()),
    };
    if decoded.len() > cap {
        return Err(format!("Upload must be at most {}MB", cap / (1024 * 1024)));
    }
    Ok((name.to_owned(), decoded, mtime))
}

async fn ingest_image_route(State(state): State<AppState>, request: Request) -> Response {
    let bytes = match to_bytes(request.into_body(), 64 * 1024 * 1024).await {
        Ok(bytes) => bytes,
        Err(_) => return error_response(StatusCode::BAD_REQUEST, "Invalid JSON body"),
    };
    let body = match serde_json::from_slice::<Value>(&bytes) {
        Ok(body) => body,
        Err(_) => return error_response(StatusCode::BAD_REQUEST, "Invalid JSON body"),
    };
    let (name, image, mtime) = match decoded_upload(&body, 48 * 1024 * 1024) {
        Ok(parts) => parts,
        Err(detail) => return error_response(StatusCode::BAD_REQUEST, detail),
    };
    match ingest_image(
        &state.pool,
        &state.vault_dir,
        &state.vision,
        name,
        image,
        mtime,
    )
    .await
    {
        Ok(outcome) => {
            if outcome.status == "ingested" {
                spawn_index(&state);
            }
            Json(outcome).into_response()
        }
        Err(error) => error_response(StatusCode::BAD_GATEWAY, error),
    }
}

async fn ingest_video_route(State(state): State<AppState>, request: Request) -> Response {
    let bytes = match to_bytes(request.into_body(), 1024 * 1024 * 1024).await {
        Ok(bytes) => bytes,
        Err(_) => return error_response(StatusCode::BAD_REQUEST, "Invalid JSON body"),
    };
    let body = match serde_json::from_slice::<Value>(&bytes) {
        Ok(body) => body,
        Err(_) => return error_response(StatusCode::BAD_REQUEST, "Invalid JSON body"),
    };
    let (name, video, mtime) = match decoded_upload(&body, 768 * 1024 * 1024) {
        Ok(parts) => parts,
        Err(detail) => return error_response(StatusCode::BAD_REQUEST, detail),
    };
    let reason = state.reason.current().await;
    let deps = VideoDeps {
        pool: &state.pool,
        vault_dir: &state.vault_dir,
        stt: &state.stt,
        vision: &state.vision,
        reason: &reason,
    };
    match ingest_video(&deps, name, video, mtime).await {
        Ok(outcome) => {
            if outcome.status == "ingested" {
                spawn_index(&state);
            }
            Json(outcome).into_response()
        }
        Err(error) => error_response(StatusCode::BAD_GATEWAY, error),
    }
}

async fn media_kind_route(Query(query): Query<HashMap<String, String>>) -> Response {
    let name = query.get("name").map(String::as_str).unwrap_or_default();
    Json(json!({ "name": name, "kind": kind_for(name) })).into_response()
}

async fn ingest_pdf_route(State(state): State<AppState>, request: Request) -> Response {
    let bytes = match to_bytes(request.into_body(), 64 * 1024 * 1024).await {
        Ok(bytes) => bytes,
        Err(_) => return error_response(StatusCode::BAD_REQUEST, "Invalid JSON body"),
    };
    let body = match serde_json::from_slice::<Value>(&bytes) {
        Ok(body) => body,
        Err(_) => return error_response(StatusCode::BAD_REQUEST, "Invalid JSON body"),
    };
    let Some(object) = body.as_object() else {
        return error_response(StatusCode::BAD_REQUEST, "Body must be an object");
    };
    let Some(name) = object
        .get("name")
        .and_then(Value::as_str)
        .filter(|value| !value.is_empty())
    else {
        return error_response(StatusCode::BAD_REQUEST, "name is required");
    };
    let Some(data) = object.get("dataB64").and_then(Value::as_str) else {
        return error_response(StatusCode::BAD_REQUEST, "dataB64 is required");
    };
    let mtime = object
        .get("mtime")
        .and_then(Value::as_str)
        .filter(|value| parse_file_date(value).is_some())
        .map(str::to_owned);
    let pdf = match base64::engine::general_purpose::STANDARD.decode(data) {
        Ok(pdf) if !pdf.is_empty() => pdf,
        _ => return error_response(StatusCode::BAD_REQUEST, "dataB64 is not valid base64"),
    };
    if pdf.len() > 48 * 1024 * 1024 {
        return error_response(StatusCode::BAD_REQUEST, "PDF must be at most 48MB");
    }

    match ingest_pdf(&state.pool, &state.vault_dir, name.to_owned(), pdf, mtime).await {
        Ok(outcome) => {
            if outcome.status == "ingested" {
                spawn_index(&state);
            }
            Json(outcome).into_response()
        }
        Err(error) => error_response(StatusCode::UNPROCESSABLE_ENTITY, error),
    }
}

async fn signals(
    State(state): State<AppState>,
    Query(query): Query<HashMap<String, String>>,
) -> Response {
    let Some(episode_id) = query
        .get("episode")
        .and_then(|value| Uuid::parse_str(value).ok())
    else {
        return error_response(StatusCode::BAD_REQUEST, "episode is required");
    };
    type SignalRow = (f32, f32, String, f32);
    let rows = sqlx::query_as::<_, SignalRow>(
        "SELECT t_start_s, t_end_s, kind, value FROM signals WHERE episode_id = $1 ORDER BY t_start_s",
    )
    .bind(episode_id)
    .fetch_all(&state.pool)
    .await;
    match rows {
        Ok(rows) => {
            let signals = rows
                .into_iter()
                .map(|(t_start_s, t_end_s, kind, value)| {
                    serde_json::json!({
                        "tStartS": t_start_s,
                        "tEndS": t_end_s,
                        "kind": kind,
                        "value": value,
                    })
                })
                .collect::<Vec<_>>();
            Json(signals).into_response()
        }
        Err(error) => error_response(StatusCode::INTERNAL_SERVER_ERROR, error),
    }
}

async fn nightly_run(State(state): State<AppState>) -> Response {
    let deps = NightlyDeps {
        pool: state.pool.clone(),
        vault_dir: state.vault_dir.to_string_lossy().into_owned(),
        embed: state.embed.clone(),
        reason: state.reason.clone(),
        connectors: state.connectors.clone(),
    };
    match record_run(&deps).await {
        Ok(run_id) => Json(serde_json::json!({ "runId": run_id })).into_response(),
        Err(error) => error_response(StatusCode::INTERNAL_SERVER_ERROR, error),
    }
}

async fn chat(State(state): State<AppState>, request: Request) -> Response {
    let reason = state.reason.current().await;
    if !reason.configured() {
        return error_response(
            StatusCode::PRECONDITION_FAILED,
            "no reasoning provider is configured on the companion",
        );
    }
    let bytes = match to_bytes(request.into_body(), 1024 * 1024).await {
        Ok(bytes) => bytes,
        Err(_) => return error_response(StatusCode::BAD_REQUEST, "Invalid JSON body"),
    };
    let body = match serde_json::from_slice::<Value>(&bytes) {
        Ok(body) => body,
        Err(_) => return error_response(StatusCode::BAD_REQUEST, "Invalid JSON body"),
    };
    let Some(message) = body
        .get("message")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|message| !message.is_empty())
        .map(str::to_owned)
    else {
        return error_response(StatusCode::BAD_REQUEST, "message is required");
    };
    let conversation_id = match body.get("conversationId") {
        None | Some(Value::Null) => None,
        Some(value) => match value.as_str().and_then(|id| Uuid::parse_str(id).ok()) {
            Some(id) => Some(id),
            None => {
                return error_response(StatusCode::BAD_REQUEST, "conversationId must be a uuid");
            }
        },
    };
    let conversation_id = match resolve_conversation(&state.pool, conversation_id, &message).await {
        Ok(id) => id,
        Err(error) if error.to_string() == "no such conversation" => {
            return error_response(StatusCode::NOT_FOUND, error);
        }
        Err(error) => return error_response(StatusCode::INTERNAL_SERVER_ERROR, error),
    };

    let persona_id = body
        .get("persona")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(str::to_owned);
    let (events, receiver) = mpsc::unbounded_channel();
    tokio::spawn(async move {
        let deps = ChatDeps {
            pool: &state.pool,
            embed: &state.embed,
            rerank: &state.rerank,
            grounding: &state.grounding,
            reason: &reason,
            persona: persona_id,
        };
        chat_stream(&deps, conversation_id, &message, &events).await;
    });
    let sse = stream::unfold(receiver, |mut receiver| async move {
        receiver.recv().await.map(|event| (event, receiver))
    })
    .map(|event| {
        let (name, data) = event_json(&event);
        Ok::<SseEvent, Infallible>(SseEvent::default().event(name).data(data.to_string()))
    });
    Sse::new(sse)
        .keep_alive(KeepAlive::default())
        .into_response()
}

async fn conversations(
    State(state): State<AppState>,
    Query(query): Query<HashMap<String, String>>,
) -> Response {
    let limit = requested_limit(query.get("limit").map(String::as_str));
    type ConversationRow = (
        Uuid,
        String,
        DateTime<Utc>,
        DateTime<Utc>,
        i64,
        Option<String>,
    );
    let rows = sqlx::query_as::<_, ConversationRow>(
        "SELECT c.id, c.title, c.created_at, c.last_active_at, (SELECT count(*) FROM messages m WHERE m.conversation_id = c.id), (SELECT content FROM messages m WHERE m.conversation_id = c.id ORDER BY created_at DESC LIMIT 1) FROM conversations c ORDER BY c.last_active_at DESC LIMIT $1",
    )
    .bind(limit)
    .fetch_all(&state.pool)
    .await;
    match rows {
        Ok(rows) => {
            let conversations = rows
                .into_iter()
                .map(|(id, title, created_at, last_active_at, count, last)| {
                    json!({
                        "id": id,
                        "title": title,
                        "createdAt": date_string(created_at),
                        "lastActiveAt": date_string(last_active_at),
                        "messageCount": count,
                        "lastMessage": last.map(|text| snippet_of(&text, 120)),
                    })
                })
                .collect::<Vec<_>>();
            Json(conversations).into_response()
        }
        Err(error) => error_response(StatusCode::INTERNAL_SERVER_ERROR, error),
    }
}

async fn conversation_detail(State(state): State<AppState>, Path(id): Path<Uuid>) -> Response {
    let conversation = sqlx::query_as::<_, (String, DateTime<Utc>)>(
        "SELECT title, created_at FROM conversations WHERE id = $1",
    )
    .bind(id)
    .fetch_optional(&state.pool)
    .await;
    let (title, created_at) = match conversation {
        Ok(Some(row)) => row,
        Ok(None) => return error_response(StatusCode::NOT_FOUND, "no such conversation"),
        Err(error) => return error_response(StatusCode::INTERNAL_SERVER_ERROR, error),
    };
    type MessageRow = (
        Uuid,
        String,
        String,
        Option<Value>,
        Option<String>,
        Option<i32>,
        DateTime<Utc>,
    );
    let rows = sqlx::query_as::<_, MessageRow>(
        "SELECT id, role, content, citations, model, latency_ms, created_at FROM messages WHERE conversation_id = $1 ORDER BY created_at ASC LIMIT 500",
    )
    .bind(id)
    .fetch_all(&state.pool)
    .await;
    match rows {
        Ok(rows) => {
            let messages = rows
                .into_iter()
                .map(
                    |(id, role, content, citations, model, latency_ms, created_at)| {
                        json!({
                            "id": id,
                            "role": role,
                            "content": content,
                            "citations": citations,
                            "model": model,
                            "latencyMs": latency_ms,
                            "createdAt": date_string(created_at),
                        })
                    },
                )
                .collect::<Vec<_>>();
            Json(json!({
                "id": id,
                "title": title,
                "createdAt": date_string(created_at),
                "messages": messages,
            }))
            .into_response()
        }
        Err(error) => error_response(StatusCode::INTERNAL_SERVER_ERROR, error),
    }
}

async fn conversation_delete(State(state): State<AppState>, Path(id): Path<Uuid>) -> Response {
    match sqlx::query("DELETE FROM conversations WHERE id = $1")
        .bind(id)
        .execute(&state.pool)
        .await
    {
        Ok(result) if result.rows_affected() == 0 => {
            error_response(StatusCode::NOT_FOUND, "no such conversation")
        }
        Ok(_) => Json(json!({"deleted": id})).into_response(),
        Err(error) => error_response(StatusCode::INTERNAL_SERVER_ERROR, error),
    }
}

async fn episode_detail(State(state): State<AppState>, Path(id): Path<Uuid>) -> Response {
    type EpisodeRow = (
        Uuid,
        DateTime<Utc>,
        DateTime<Utc>,
        String,
        String,
        Option<String>,
        Option<String>,
        Vec<String>,
        Option<f64>,
        Option<String>,
        String,
        i64,
        i64,
    );
    let row = sqlx::query_as::<_, EpisodeRow>(
        "SELECT e.id, e.occurred_at, e.ingested_at, e.kind, e.title, e.body_original, e.body_en, COALESCE(e.langs, '{}'), e.duration_s::float8, e.media_ref, s.sha256, s.bytes, (SELECT count(*) FROM chunks c WHERE c.episode_id = e.id) FROM episodes e JOIN sources s ON s.id = e.source_id WHERE e.id = $1",
    )
    .bind(id)
    .fetch_optional(&state.pool)
    .await;
    match row {
        Ok(Some((
            id,
            occurred_at,
            ingested_at,
            kind,
            title,
            body,
            body_en,
            langs,
            duration_s,
            media_ref,
            sha256,
            bytes,
            chunks,
        ))) => Json(json!({
            "id": id,
            "occurredAt": date_string(occurred_at),
            "ingestedAt": date_string(ingested_at),
            "kind": kind,
            "title": title,
            "body": body,
            "bodyEn": body_en,
            "langs": langs,
            "durationS": duration_s,
            "mediaRef": media_ref,
            "sha256": sha256,
            "bytes": bytes,
            "chunks": chunks,
        }))
        .into_response(),
        Ok(None) => error_response(StatusCode::NOT_FOUND, "no such episode"),
        Err(error) => error_response(StatusCode::INTERNAL_SERVER_ERROR, error),
    }
}

pub fn media_content_type(uri: &str) -> &'static str {
    let extension = uri.rsplit('.').next().unwrap_or_default().to_lowercase();
    match extension.as_str() {
        "md" | "markdown" => "text/markdown; charset=utf-8",
        "pdf" => "application/pdf",
        "wav" => "audio/wav",
        "m4a" => "audio/mp4",
        "mp3" => "audio/mpeg",
        "ogg" => "audio/ogg",
        "flac" => "audio/flac",
        "aiff" => "audio/aiff",
        _ => "application/octet-stream",
    }
}

async fn episode_media(State(state): State<AppState>, Path(id): Path<Uuid>) -> Response {
    let row = sqlx::query_as::<_, (String,)>(
        "SELECT s.uri FROM episodes e JOIN sources s ON s.id = e.source_id WHERE e.id = $1",
    )
    .bind(id)
    .fetch_optional(&state.pool)
    .await;
    let uri = match row {
        Ok(Some((uri,))) => uri,
        Ok(None) => return error_response(StatusCode::NOT_FOUND, "no such episode"),
        Err(error) => return error_response(StatusCode::INTERNAL_SERVER_ERROR, error),
    };
    match tokio::fs::read(state.vault_dir.join(&uri)).await {
        Ok(bytes) => (
            StatusCode::OK,
            [(axum::http::header::CONTENT_TYPE, media_content_type(&uri))],
            bytes,
        )
            .into_response(),
        Err(error) => error_response(
            StatusCode::NOT_FOUND,
            format!("media unavailable in the vault: {error}"),
        ),
    }
}

fn api_key_hint(key: &str) -> String {
    if key.chars().count() < 8 {
        return String::new();
    }
    let tail = key
        .chars()
        .rev()
        .take(4)
        .collect::<Vec<_>>()
        .into_iter()
        .rev()
        .collect::<String>();
    format!("\u{2026}{tail}")
}

async fn reason_settings_payload(state: &AppState) -> Value {
    let reason = state.reason.current().await;
    let config = reason.config();
    json!({
        "provider": reason.provider_name(),
        "url": config.url,
        "model": reason.model_name(),
        "hasApiKey": !config.api_key.is_empty(),
        "apiKeyHint": api_key_hint(&config.api_key),
        "configured": reason.configured(),
        "description": reason.describe(),
    })
}

async fn reason_settings(State(state): State<AppState>) -> Response {
    Json(reason_settings_payload(&state).await).into_response()
}

async fn reason_settings_put(State(state): State<AppState>, request: Request) -> Response {
    let bytes = match to_bytes(request.into_body(), 64 * 1024).await {
        Ok(bytes) => bytes,
        Err(_) => return error_response(StatusCode::BAD_REQUEST, "Invalid JSON body"),
    };
    let body = match serde_json::from_slice::<Value>(&bytes) {
        Ok(Value::Object(body)) => body,
        _ => return error_response(StatusCode::BAD_REQUEST, "Body must be an object"),
    };
    let fields = [
        ("provider", settings::REASON_PROVIDER),
        ("url", settings::REASON_URL),
        ("model", settings::REASON_MODEL),
        ("apiKey", settings::REASON_API_KEY),
    ];
    if let Some(provider) = body.get("provider").and_then(Value::as_str)
        && !["", "anthropic", "openai"].contains(&provider.trim())
    {
        return error_response(
            StatusCode::BAD_REQUEST,
            "provider must be anthropic or openai",
        );
    }
    for (field, key) in fields {
        let Some(value) = body.get(field) else {
            continue;
        };
        let Some(value) = value.as_str() else {
            return error_response(StatusCode::BAD_REQUEST, format!("{field} must be a string"));
        };
        let result = if value.trim().is_empty() {
            settings::remove(&state.pool, key).await
        } else {
            settings::put(&state.pool, key, value.trim()).await
        };
        if let Err(error) = result {
            return error_response(StatusCode::INTERNAL_SERVER_ERROR, error);
        }
    }
    let config = settings::reason_config(&state.pool).await;
    state
        .reason
        .replace(ReasonClient::from_config(config))
        .await;
    Json(reason_settings_payload(&state).await).into_response()
}

async fn reason_settings_test(State(state): State<AppState>) -> Response {
    let reason = state.reason.current().await;
    if !reason.configured() {
        return error_response(
            StatusCode::PRECONDITION_FAILED,
            "no reasoning provider is configured on the companion",
        );
    }
    let started = std::time::Instant::now();
    match reason
        .complete("Reply with the single word ok.", "ping")
        .await
    {
        Ok(_) => Json(json!({
            "ok": true,
            "model": reason.describe(),
            "latencyMs": latency_since(started),
        }))
        .into_response(),
        Err(error) => error_response(StatusCode::BAD_GATEWAY, error),
    }
}

fn snippet_of(text: &str, limit: usize) -> String {
    let squeezed = text.split_whitespace().collect::<Vec<_>>().join(" ");
    if squeezed.chars().count() <= limit {
        return squeezed;
    }
    let cut = squeezed
        .char_indices()
        .nth(limit)
        .map_or(squeezed.len(), |(i, _)| i);
    format!("{}\u{2026}", &squeezed[..cut])
}

async fn runs(
    State(state): State<AppState>,
    Query(query): Query<HashMap<String, String>>,
) -> Response {
    let limit = requested_limit(query.get("limit").map(String::as_str));
    type RunRow = (Uuid, DateTime<Utc>, Option<DateTime<Utc>>, bool, Value);
    let rows = sqlx::query_as::<_, RunRow>(
        "SELECT id, started_at, finished_at, ok, steps FROM nightly_runs ORDER BY started_at DESC LIMIT $1",
    )
    .bind(limit)
    .fetch_all(&state.pool)
    .await;
    match rows {
        Ok(rows) => {
            let runs = rows
                .into_iter()
                .map(|(id, started_at, finished_at, ok, steps)| {
                    serde_json::json!({
                        "id": id,
                        "startedAt": date_string(started_at),
                        "finishedAt": finished_at.map(date_string),
                        "ok": ok,
                        "steps": steps,
                    })
                })
                .collect::<Vec<_>>();
            Json(runs).into_response()
        }
        Err(error) => error_response(StatusCode::INTERNAL_SERVER_ERROR, error),
    }
}

async fn claims_extract(State(state): State<AppState>) -> Response {
    let reason = state.reason.current().await;
    if !reason.configured() {
        return error_response(
            StatusCode::PRECONDITION_FAILED,
            "no reasoning provider is configured on the companion",
        );
    }
    match extract_claims(&state.pool, &reason).await {
        Ok(outcome) => Json(outcome).into_response(),
        Err(error) => error_response(StatusCode::BAD_GATEWAY, error),
    }
}

async fn corroborate(State(state): State<AppState>) -> Response {
    let reason = state.reason.current().await;
    if !reason.configured() {
        return error_response(
            StatusCode::PRECONDITION_FAILED,
            "no reasoning provider is configured on the companion",
        );
    }
    match corroborate_claims(&state.pool, &reason).await {
        Ok(outcome) => Json(outcome).into_response(),
        Err(error) => error_response(StatusCode::BAD_GATEWAY, error),
    }
}

async fn claims(
    State(state): State<AppState>,
    Query(query): Query<HashMap<String, String>>,
) -> Response {
    let limit = requested_limit(query.get("limit").map(String::as_str));
    type ClaimRow = (
        Uuid,
        String,
        String,
        bool,
        DateTime<Utc>,
        Option<Uuid>,
        Option<String>,
        Option<String>,
        Option<Vec<Uuid>>,
    );
    let rows = sqlx::query_as::<_, ClaimRow>(
        "SELECT c.id, c.statement, c.claim_type, c.testable, c.asserted_at, c.episode_id, x.verdict, x.note, x.observation_ids FROM claims c LEFT JOIN LATERAL (SELECT verdict, note, observation_ids FROM corroborations WHERE claim_id = c.id ORDER BY checked_at DESC LIMIT 1) x ON true ORDER BY c.asserted_at DESC LIMIT $1",
    )
    .bind(limit)
    .fetch_all(&state.pool)
    .await;
    match rows {
        Ok(rows) => {
            let claims = rows
                .into_iter()
                .map(
                    |(
                        id,
                        statement,
                        claim_type,
                        testable,
                        asserted_at,
                        episode_id,
                        verdict,
                        note,
                        observation_ids,
                    )| {
                        serde_json::json!({
                            "id": id,
                            "statement": statement,
                            "claimType": claim_type,
                            "testable": testable,
                            "assertedAt": date_string(asserted_at),
                            "episodeId": episode_id,
                            "verdict": verdict,
                            "verdictNote": note,
                            "observationIds": observation_ids.unwrap_or_default(),
                        })
                    },
                )
                .collect::<Vec<_>>();
            Json(claims).into_response()
        }
        Err(error) => error_response(StatusCode::INTERNAL_SERVER_ERROR, error),
    }
}

async fn reflect(State(state): State<AppState>) -> Response {
    let reason = state.reason.current().await;
    if !reason.configured() {
        return error_response(
            StatusCode::PRECONDITION_FAILED,
            "no reasoning provider is configured on the companion",
        );
    }
    match reflect_run(&state.pool, &state.embed, &reason).await {
        Ok(outcome) => Json(outcome).into_response(),
        Err(error) => error_response(StatusCode::BAD_GATEWAY, error),
    }
}

async fn beliefs(
    State(state): State<AppState>,
    Query(query): Query<HashMap<String, String>>,
) -> Response {
    let limit = requested_limit(query.get("limit").map(String::as_str));
    type BeliefRow = (Uuid, String, String, f32, DateTime<Utc>, Vec<Uuid>, String);
    let rows = sqlx::query_as::<_, BeliefRow>(
        "SELECT id, statement, kind, confidence, first_formed, evidence_episode_ids, status FROM beliefs ORDER BY first_formed DESC LIMIT $1",
    )
    .bind(limit)
    .fetch_all(&state.pool)
    .await;
    match rows {
        Ok(rows) => {
            let beliefs = rows
                .into_iter()
                .map(
                    |(id, statement, kind, confidence, first_formed, evidence, status)| {
                        serde_json::json!({
                            "id": id,
                            "statement": statement,
                            "kind": kind,
                            "confidence": confidence,
                            "firstFormed": date_string(first_formed),
                            "evidenceEpisodeIds": evidence,
                            "status": status,
                        })
                    },
                )
                .collect::<Vec<_>>();
            Json(beliefs).into_response()
        }
        Err(error) => error_response(StatusCode::INTERNAL_SERVER_ERROR, error),
    }
}

async fn github_sync(State(state): State<AppState>) -> Response {
    let github = state.connectors.github().await;
    if !github.configured() {
        return error_response(
            StatusCode::PRECONDITION_FAILED,
            "no github token; set it in Settings or with `ed companion connectors set`",
        );
    }
    match github.sync(&state.pool).await {
        Ok(outcome) => Json(outcome).into_response(),
        Err(error) => error_response(StatusCode::BAD_GATEWAY, error),
    }
}

async fn notion_sync(
    State(state): State<AppState>,
    Query(query): Query<HashMap<String, String>>,
) -> Response {
    let notion = state.connectors.notion().await;
    if !notion.configured() {
        return error_response(
            StatusCode::PRECONDITION_FAILED,
            "no notion token; set it in Settings or with `ed companion connectors set`",
        );
    }
    let full = query
        .get("full")
        .map(|value| value == "true" || value == "1")
        .unwrap_or(false);
    match notion.sync(&state.pool, &state.vault_dir, full).await
    {
        Ok(outcome) => {
            spawn_index(&state);
            Json(outcome).into_response()
        }
        Err(error) => error_response(StatusCode::BAD_GATEWAY, error),
    }
}

async fn observations(
    State(state): State<AppState>,
    Query(query): Query<HashMap<String, String>>,
) -> Response {
    let limit = requested_limit(query.get("limit").map(String::as_str));
    let kind = query
        .get("kind")
        .map(String::as_str)
        .filter(|value| !value.is_empty());
    type ObservationRow = (Uuid, String, DateTime<Utc>, String, Value);
    let rows = sqlx::query_as::<_, ObservationRow>(
        "SELECT id, source, observed_at, kind, payload FROM observations WHERE ($1::text IS NULL OR kind = $1) ORDER BY observed_at DESC LIMIT $2",
    )
    .bind(kind)
    .bind(limit)
    .fetch_all(&state.pool)
    .await;
    match rows {
        Ok(rows) => {
            let observations = rows
                .into_iter()
                .map(|(id, source, observed_at, kind, payload)| {
                    let summary = observation_summary(&kind, &payload);
                    serde_json::json!({
                        "id": id,
                        "source": source,
                        "observedAt": date_string(observed_at),
                        "kind": kind,
                        "summary": summary,
                        "payload": payload,
                    })
                })
                .collect::<Vec<_>>();
            Json(observations).into_response()
        }
        Err(error) => error_response(StatusCode::INTERNAL_SERVER_ERROR, error),
    }
}

fn observation_summary(kind: &str, payload: &Value) -> String {
    let text = |key: &str| {
        payload
            .get(key)
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_owned()
    };
    let number = payload.get("number").and_then(Value::as_i64).unwrap_or(0);
    match kind {
        "commit" => {
            let sha = text("sha");
            let short = sha.get(..7).unwrap_or(&sha);
            format!("{} {short} {}", text("repo"), text("message"))
        }
        "pull_request" => format!(
            "{} #{number} {} {}",
            text("repo"),
            text("action"),
            text("title")
        ),
        "issue" => format!(
            "{} #{number} {} {}",
            text("repo"),
            text("action"),
            text("title")
        ),
        "review" => format!("{} #{number} {}", text("repo"), text("state")),
        _ => text("repo"),
    }
}

async fn index(State(state): State<AppState>) -> Response {
    match index_pending(&state.pool, &state.embed).await {
        Ok(outcome) => Json(outcome).into_response(),
        Err(failure) => {
            let status = if failure.is_embedding() {
                StatusCode::BAD_GATEWAY
            } else {
                StatusCode::INTERNAL_SERVER_ERROR
            };
            error_response(status, failure)
        }
    }
}

fn snippet(text: &str) -> String {
    if text.chars().count() <= 300 {
        return text.to_owned();
    }
    let cut = text.char_indices().nth(300).map_or(text.len(), |(i, _)| i);
    format!("{}\u{2026}", &text[..cut])
}

async fn search(
    State(state): State<AppState>,
    Query(query): Query<HashMap<String, String>>,
) -> Response {
    let started = std::time::Instant::now();
    let Some(q) = query
        .get("q")
        .map(|value| value.trim())
        .filter(|value| !value.is_empty())
    else {
        return error_response(StatusCode::BAD_REQUEST, "q is required");
    };
    let k = query
        .get("k")
        .and_then(|value| value.trim().parse::<i64>().ok())
        .unwrap_or(8)
        .clamp(1, 50) as usize;

    let policy = RetrievalPolicy {
        k,
        ..RetrievalPolicy::default()
    };
    let outcome = match retrieve(&state.pool, &state.embed, &state.rerank, q, &policy).await {
        Ok(outcome) => outcome,
        Err(error) => return error_response(StatusCode::INTERNAL_SERVER_ERROR, error),
    };

    let results = outcome
        .items
        .iter()
        .map(|item| SearchResult {
            chunk_id: item.item_id,
            episode_id: item.episode_id.unwrap_or(item.item_id),
            ord: 0,
            title: item.title.clone(),
            occurred_at: date_string(item.occurred_at),
            kind: item.item_type.clone(),
            snippet: snippet(&item.text),
            score: ((item.scores.rerank.unwrap_or(item.scores.fused) as f64) * 1e6).round() / 1e6,
        })
        .collect::<Vec<_>>();

    let retrieved = outcome
        .items
        .iter()
        .enumerate()
        .map(|(rank, item)| RetrievedChunk::from_item(item, rank as i32 + 1, false))
        .collect::<Vec<_>>();
    log_turn(
        &state.pool,
        "search",
        q,
        None,
        latency_since(started),
        &retrieved,
    )
    .await;
    Json(results).into_response()
}

async fn status(State(state): State<AppState>) -> Response {
    let result = sqlx::query_as::<_, (i64, i64, i64, i64, i64, i64, Option<DateTime<Utc>>)>(
        "SELECT (SELECT count(*) FROM sources), (SELECT count(*) FROM episodes), (SELECT count(*) FROM claims), (SELECT count(*) FROM observations), (SELECT count(*) FROM chunks), (SELECT count(*) FROM episodes e WHERE NOT EXISTS (SELECT 1 FROM chunks c WHERE c.episode_id = e.id)), (SELECT max(ingested_at) FROM episodes)",
    )
    .fetch_one(&state.pool)
    .await;

    match result {
        Ok((
            sources,
            episodes,
            claims,
            observations,
            chunks,
            pending_episodes,
            latest_ingested_at,
        )) => Json(StatusResult {
            sources,
            episodes,
            claims,
            observations,
            chunks,
            pending_episodes,
            latest_ingested_at: latest_ingested_at.map(date_string),
        })
        .into_response(),
        Err(error) => error_response(StatusCode::INTERNAL_SERVER_ERROR, error),
    }
}

fn requested_limit(value: Option<&str>) -> i64 {
    let numeric = match value {
        None => 20.0,
        Some(value) if value.trim().is_empty() => 0.0,
        Some(value) => value.trim().parse::<f64>().unwrap_or(20.0),
    };
    let integral = if numeric.is_finite() {
        numeric.trunc()
    } else {
        20.0
    };
    integral.clamp(1.0, 200.0) as i64
}

async fn episodes(
    State(state): State<AppState>,
    Query(query): Query<HashMap<String, String>>,
) -> Response {
    let limit = requested_limit(query.get("limit").map(String::as_str));
    let result = sqlx::query_as::<_, (Uuid, DateTime<Utc>, String, String, String)>(
        "SELECT e.id, e.occurred_at, e.kind, e.title, s.sha256 FROM episodes e JOIN sources s ON s.id = e.source_id ORDER BY e.occurred_at DESC LIMIT $1",
    )
    .bind(limit)
    .fetch_all(&state.pool)
    .await;

    match result {
        Ok(rows) => {
            let episodes = rows
                .into_iter()
                .map(|(id, occurred_at, kind, title, sha256)| EpisodeResult {
                    id,
                    occurred_at: date_string(occurred_at),
                    kind,
                    title,
                    sha256,
                })
                .collect::<Vec<_>>();
            Json(episodes).into_response()
        }
        Err(error) => error_response(StatusCode::INTERNAL_SERVER_ERROR, error),
    }
}

pub fn router(state: AppState) -> Router {
    Router::new()
        .route("/v1/health", get(health))
        .route("/v1/ingest", post(ingest))
        .route("/v1/ingest/audio", post(ingest_audio_route))
        .route("/v1/ingest/pdf", post(ingest_pdf_route))
        .route("/v1/ingest/image", post(ingest_image_route))
        .route("/v1/ingest/video", post(ingest_video_route))
        .route("/v1/media/kind", get(media_kind_route))
        .route("/v1/index", post(index))
        .route("/v1/search", get(search))
        .route("/v1/connectors/github/sync", post(github_sync))
        .route("/v1/connectors/notion/sync", post(notion_sync))
        .route("/v1/observations", get(observations))
        .route("/v1/reflect", post(reflect))
        .route("/v1/beliefs", get(beliefs))
        .route("/v1/ask", post(ask))
        .route("/v1/council", post(council))
        .route("/v1/personas", get(personas))
        .route("/v1/core", get(core_memory_route).post(core_memory_write))
        .route("/v1/baselines", get(baselines))
        .route("/v1/hypotheses", get(hypotheses_route))
        .route("/v1/hypotheses/run", post(hypotheses_run))
        .route("/v1/predictions", get(predictions_route))
        .route("/v1/commitments", get(commitments_route))
        .route("/v1/discrepancies", get(discrepancies_route))
        .route("/v1/discrepancies/{id}/override", post(discrepancy_override))
        .route("/v1/calibration", get(calibration_route))
        .route("/v1/questions", get(questions_route))
        .route("/v1/questions/next", post(question_next))
        .route("/v1/questions/{id}/answer", post(question_answer))
        .route("/v1/questions/{id}/skip", post(question_skip))
        .route("/v1/questions/mute", post(question_mute))
        .route("/v1/entities", get(entities_route))
        .route("/v1/lenses", get(lenses_route))
        .route("/v1/memory/why/{id}", get(memory_why))
        .route("/v1/settings/connectors", get(connectors_show).post(connectors_set))
        .route("/v1/connectors/{source}/import", post(connectors_import))
        .route("/v1/connectors/edith/usage", post(usage_route))
        .route("/v1/facts", get(facts_route))
        .route("/v1/beliefs/{id}/correct", post(belief_correct))
        .route("/v1/reflect/weekly", post(weekly_route))
        .route("/v1/db/{action}", post(db_route))
        .route("/v1/turns/{id}/feedback", post(feedback_route))
        .route("/v1/evals", get(evals_route))
        .route("/v1/evals/run", post(evals_run))
        .route("/v1/standup", post(standup_route))
        .route("/v1/standup/aggregate", get(standup_aggregate))
        .route("/v1/machines", get(machines_route).post(machines_add))
        .route("/v1/machines/plan", get(machines_plan))
        .route("/v1/machines/{name}/probe", post(machines_probe))
        .route("/v1/machines/{name}/profile", post(machines_profile))
        .route("/v1/chat", post(chat))
        .route("/v1/conversations", get(conversations))
        .route(
            "/v1/conversations/{id}",
            get(conversation_detail).delete(conversation_delete),
        )
        .route(
            "/v1/settings/reason",
            get(reason_settings).put(reason_settings_put),
        )
        .route("/v1/settings/reason/test", post(reason_settings_test))
        .route("/v1/claims/extract", post(claims_extract))
        .route("/v1/claims", get(claims))
        .route("/v1/corroborate", post(corroborate))
        .route("/v1/nightly/run", post(nightly_run))
        .route("/v1/runs", get(runs))
        .route("/v1/signals", get(signals))
        .route("/v1/status", get(status))
        .route("/v1/episodes", get(episodes))
        .route("/v1/episodes/{id}", get(episode_detail))
        .route("/v1/episodes/{id}/media", get(episode_media))
        .with_state(state)
}
