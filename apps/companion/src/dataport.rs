use std::error::Error;
use std::path::{Component, Path, PathBuf};

use chrono::{DateTime, SecondsFormat, Utc};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sqlx::PgPool;
use uuid::Uuid;

use crate::vault::write_vault_file;

pub const FORMAT: &str = "edith-companion-export";
pub const VERSION: i64 = 1;
pub const WIPE_CONFIRMATION: &str = "everything";

async fn table_json(pool: &PgPool, query: &'static str) -> Result<Value, sqlx::Error> {
    sqlx::query_scalar::<_, Value>(query).fetch_one(pool).await
}

pub async fn export(pool: &PgPool) -> Result<Value, sqlx::Error> {
    let episodes = table_json(
        pool,
        "SELECT coalesce(jsonb_agg(t ORDER BY t->>'ingestedAt'), '[]'::jsonb) FROM (SELECT jsonb_build_object('id', e.id, 'occurredAt', e.occurred_at, 'ingestedAt', e.ingested_at, 'kind', e.kind, 'title', e.title, 'bodyOriginal', e.body_original, 'bodyEn', e.body_en, 'langs', e.langs, 'script', e.script, 'translatedBy', e.translated_by, 'mediaRef', e.media_ref, 'durationS', e.duration_s, 'persona', e.persona, 'meta', e.meta, 'source', jsonb_build_object('kind', s.kind, 'uri', s.uri, 'sha256', s.sha256, 'bytes', s.bytes, 'importedAt', s.imported_at, 'connectorMeta', s.connector_meta)) AS t FROM episodes e JOIN sources s ON s.id = e.source_id) x",
    )
    .await?;
    let observations = table_json(
        pool,
        "SELECT coalesce(jsonb_agg(jsonb_build_object('id', id, 'source', source, 'observedAt', observed_at, 'kind', kind, 'payload', payload, 'dedupeKey', dedupe_key)), '[]'::jsonb) FROM observations",
    )
    .await?;
    let conversations = table_json(
        pool,
        "SELECT coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'title', c.title, 'createdAt', c.created_at, 'lastActiveAt', c.last_active_at, 'messages', (SELECT coalesce(jsonb_agg(jsonb_build_object('id', m.id, 'role', m.role, 'content', m.content, 'citations', m.citations, 'model', m.model, 'latencyMs', m.latency_ms, 'createdAt', m.created_at) ORDER BY m.created_at), '[]'::jsonb) FROM messages m WHERE m.conversation_id = c.id))), '[]'::jsonb) FROM conversations c",
    )
    .await?;
    let beliefs = table_json(
        pool,
        "SELECT coalesce(jsonb_agg(jsonb_build_object('id', id, 'statement', statement, 'kind', kind, 'confidence', confidence, 'stability', stability, 'corroboration', corroboration, 'firstFormed', first_formed, 'lastConfirmed', last_confirmed, 'supersededBy', superseded_by, 'evidenceEpisodeIds', evidence_episode_ids, 'counterEvidenceEpisodeIds', counter_evidence_episode_ids, 'extractorVersion', extractor_version, 'status', status)), '[]'::jsonb) FROM beliefs",
    )
    .await?;
    let claims = table_json(
        pool,
        "SELECT coalesce(jsonb_agg(jsonb_build_object('id', id, 'episodeId', episode_id, 'statement', statement, 'subject', subject, 'predicate', predicate, 'object', object, 'assertedAt', asserted_at, 'hedging', hedging, 'claimType', claim_type, 'testable', testable, 'expectedObservable', expected_observable)), '[]'::jsonb) FROM claims",
    )
    .await?;
    let facts = table_json(
        pool,
        "SELECT coalesce(jsonb_agg(jsonb_build_object('id', id, 'subjectId', subject_id, 'predicate', predicate, 'objectId', object_id, 'objectLiteral', object_literal, 'validFrom', valid_from, 'validTo', valid_to, 'createdAt', created_at, 'expiredAt', expired_at, 'confidence', confidence, 'supersededBy', superseded_by, 'sourceEpisodeIds', source_episode_ids, 'extractorVersion', extractor_version)), '[]'::jsonb) FROM facts",
    )
    .await?;
    let core_memory = table_json(
        pool,
        "SELECT coalesce(jsonb_agg(jsonb_build_object('section', section, 'content', content, 'updatedAt', updated_at, 'updatedBy', updated_by)), '[]'::jsonb) FROM core_memory",
    )
    .await?;
    let settings = table_json(
        pool,
        "SELECT coalesce(jsonb_object_agg(key, value), '{}'::jsonb) FROM settings WHERE key IN ('reason.provider', 'reason.url', 'reason.model')",
    )
    .await?;
    let media = table_json(
        pool,
        "SELECT coalesce(jsonb_agg(jsonb_build_object('episodeId', e.id, 'uri', s.uri, 'sha256', s.sha256, 'bytes', s.bytes)), '[]'::jsonb) FROM episodes e JOIN sources s ON s.id = e.source_id WHERE e.media_ref IS NOT NULL",
    )
    .await?;
    let counts = json!({
        "episodes": episodes.as_array().map(Vec::len).unwrap_or(0),
        "observations": observations.as_array().map(Vec::len).unwrap_or(0),
        "conversations": conversations.as_array().map(Vec::len).unwrap_or(0),
        "beliefs": beliefs.as_array().map(Vec::len).unwrap_or(0),
        "claims": claims.as_array().map(Vec::len).unwrap_or(0),
        "facts": facts.as_array().map(Vec::len).unwrap_or(0),
        "media": media.as_array().map(Vec::len).unwrap_or(0),
    });
    Ok(json!({
        "format": FORMAT,
        "version": VERSION,
        "exportedAt": Utc::now().to_rfc3339_opts(SecondsFormat::AutoSi, true),
        "counts": counts,
        "episodes": episodes,
        "observations": observations,
        "conversations": conversations,
        "beliefs": beliefs,
        "claims": claims,
        "facts": facts,
        "coreMemory": core_memory,
        "settings": settings,
        "media": media,
    }))
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct BundleSource {
    pub kind: String,
    pub uri: String,
    pub sha256: String,
    pub bytes: i64,
    pub imported_at: Option<DateTime<Utc>>,
    #[serde(default)]
    pub connector_meta: Value,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct BundleEpisode {
    pub id: Uuid,
    pub occurred_at: DateTime<Utc>,
    pub ingested_at: Option<DateTime<Utc>>,
    pub kind: String,
    pub title: String,
    pub body_original: String,
    pub body_en: Option<String>,
    #[serde(default)]
    pub langs: Vec<String>,
    pub script: Option<String>,
    pub translated_by: Option<String>,
    pub media_ref: Option<String>,
    pub duration_s: Option<f64>,
    pub persona: Option<String>,
    #[serde(default)]
    pub meta: Value,
    pub source: BundleSource,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct BundleObservation {
    pub id: Uuid,
    pub source: String,
    pub observed_at: DateTime<Utc>,
    pub kind: String,
    #[serde(default)]
    pub payload: Value,
    pub dedupe_key: Option<String>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct BundleMessage {
    pub id: Uuid,
    pub role: String,
    pub content: String,
    pub citations: Option<Value>,
    pub model: Option<String>,
    pub latency_ms: Option<i32>,
    pub created_at: DateTime<Utc>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct BundleConversation {
    pub id: Uuid,
    pub title: String,
    pub created_at: DateTime<Utc>,
    pub last_active_at: DateTime<Utc>,
    #[serde(default)]
    pub messages: Vec<BundleMessage>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct BundleBelief {
    pub id: Uuid,
    pub statement: String,
    pub kind: String,
    pub confidence: f64,
    pub stability: f64,
    pub corroboration: String,
    pub first_formed: DateTime<Utc>,
    pub last_confirmed: DateTime<Utc>,
    pub superseded_by: Option<Uuid>,
    #[serde(default)]
    pub evidence_episode_ids: Vec<Uuid>,
    #[serde(default)]
    pub counter_evidence_episode_ids: Vec<Uuid>,
    pub extractor_version: String,
    pub status: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct BundleClaim {
    pub id: Uuid,
    pub episode_id: Uuid,
    pub statement: String,
    pub subject: Option<String>,
    pub predicate: Option<String>,
    pub object: Option<String>,
    pub asserted_at: DateTime<Utc>,
    pub hedging: Option<String>,
    pub claim_type: String,
    pub testable: bool,
    pub expected_observable: Option<Value>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct BundleFact {
    pub id: Uuid,
    pub subject_id: Option<Uuid>,
    pub predicate: String,
    pub object_id: Option<Uuid>,
    pub object_literal: Option<String>,
    pub valid_from: Option<DateTime<Utc>>,
    pub valid_to: Option<DateTime<Utc>>,
    pub created_at: Option<DateTime<Utc>>,
    pub expired_at: Option<DateTime<Utc>>,
    pub confidence: Option<f64>,
    pub superseded_by: Option<Uuid>,
    #[serde(default)]
    pub source_episode_ids: Vec<Uuid>,
    pub extractor_version: Option<String>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct BundleCoreSection {
    pub section: String,
    pub content: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Bundle {
    pub format: String,
    pub version: i64,
    #[serde(default)]
    pub episodes: Vec<BundleEpisode>,
    #[serde(default)]
    pub observations: Vec<BundleObservation>,
    #[serde(default)]
    pub conversations: Vec<BundleConversation>,
    #[serde(default)]
    pub beliefs: Vec<BundleBelief>,
    #[serde(default)]
    pub claims: Vec<BundleClaim>,
    #[serde(default)]
    pub facts: Vec<BundleFact>,
    #[serde(default)]
    pub core_memory: Vec<BundleCoreSection>,
    #[serde(default)]
    pub settings: std::collections::HashMap<String, String>,
}

#[derive(Debug, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ImportOutcome {
    pub episodes_inserted: u64,
    pub episodes_skipped: u64,
    pub observations_inserted: u64,
    pub conversations_inserted: u64,
    pub messages_inserted: u64,
    pub beliefs_inserted: u64,
    pub claims_inserted: u64,
    pub claims_skipped: u64,
    pub facts_inserted: u64,
    pub core_sections_inserted: u64,
    pub settings_inserted: u64,
    pub vault_files_written: u64,
    pub pending_episodes: i64,
}

pub fn validate(bundle: &Bundle) -> Result<(), String> {
    if bundle.format != FORMAT {
        return Err(format!(
            "this is not a companion export; format is {}, expected {FORMAT}",
            bundle.format
        ));
    }
    if bundle.version > VERSION {
        return Err(format!(
            "this export is format version {}, and this companion only reads up to {VERSION}; update the companion first",
            bundle.version
        ));
    }
    Ok(())
}

const IMPORTABLE_SETTINGS: [&str; 3] = ["reason.provider", "reason.url", "reason.model"];

pub async fn import(
    pool: &PgPool,
    vault_dir: &Path,
    bundle: Bundle,
) -> Result<ImportOutcome, Box<dyn Error + Send + Sync>> {
    let mut outcome = ImportOutcome::default();

    for episode in &bundle.episodes {
        let basename = Path::new(&episode.source.uri)
            .file_name()
            .map(|name| name.to_string_lossy().into_owned())
            .unwrap_or_else(|| format!("{}.md", episode.id));
        if episode.media_ref.is_none() {
            write_vault_file(
                vault_dir,
                &episode.source.sha256,
                &basename,
                episode.body_original.as_bytes(),
            )
            .await?;
            outcome.vault_files_written += 1;
        }
        sqlx::query(
            "INSERT INTO sources (kind, uri, sha256, bytes, imported_at, connector_meta) VALUES ($1, $2, $3, $4, coalesce($5, now()), coalesce($6, '{}'::jsonb)) ON CONFLICT (sha256) DO NOTHING",
        )
        .bind(&episode.source.kind)
        .bind(&episode.source.uri)
        .bind(&episode.source.sha256)
        .bind(episode.source.bytes)
        .bind(episode.source.imported_at)
        .bind(&episode.source.connector_meta)
        .execute(pool)
        .await?;
        let source_id =
            sqlx::query_scalar::<_, Uuid>("SELECT id FROM sources WHERE sha256 = $1")
                .bind(&episode.source.sha256)
                .fetch_one(pool)
                .await?;
        let inserted = sqlx::query(
            "INSERT INTO episodes (id, source_id, occurred_at, ingested_at, kind, title, body_original, body_en, langs, script, translated_by, media_ref, duration_s, persona, meta) VALUES ($1, $2, $3, coalesce($4, now()), $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, coalesce($15, '{}'::jsonb)) ON CONFLICT DO NOTHING",
        )
        .bind(episode.id)
        .bind(source_id)
        .bind(episode.occurred_at)
        .bind(episode.ingested_at)
        .bind(&episode.kind)
        .bind(&episode.title)
        .bind(&episode.body_original)
        .bind(&episode.body_en)
        .bind(&episode.langs)
        .bind(&episode.script)
        .bind(&episode.translated_by)
        .bind(&episode.media_ref)
        .bind(episode.duration_s.map(|value| value as f32))
        .bind(&episode.persona)
        .bind(&episode.meta)
        .execute(pool)
        .await?;
        if inserted.rows_affected() == 0 {
            outcome.episodes_skipped += 1;
        } else {
            outcome.episodes_inserted += inserted.rows_affected();
        }
    }

    for observation in &bundle.observations {
        let inserted = sqlx::query(
            "INSERT INTO observations (id, source, observed_at, kind, payload, dedupe_key) VALUES ($1, $2, $3, $4, coalesce($5, '{}'::jsonb), $6) ON CONFLICT DO NOTHING",
        )
        .bind(observation.id)
        .bind(&observation.source)
        .bind(observation.observed_at)
        .bind(&observation.kind)
        .bind(&observation.payload)
        .bind(&observation.dedupe_key)
        .execute(pool)
        .await?;
        outcome.observations_inserted += inserted.rows_affected();
    }

    for conversation in &bundle.conversations {
        let inserted = sqlx::query(
            "INSERT INTO conversations (id, title, created_at, last_active_at) VALUES ($1, $2, $3, $4) ON CONFLICT DO NOTHING",
        )
        .bind(conversation.id)
        .bind(&conversation.title)
        .bind(conversation.created_at)
        .bind(conversation.last_active_at)
        .execute(pool)
        .await?;
        outcome.conversations_inserted += inserted.rows_affected();
        for message in &conversation.messages {
            let inserted = sqlx::query(
                "INSERT INTO messages (id, conversation_id, role, content, citations, model, latency_ms, created_at) VALUES ($1, $2, $3, $4, $5, $6, $7, $8) ON CONFLICT DO NOTHING",
            )
            .bind(message.id)
            .bind(conversation.id)
            .bind(&message.role)
            .bind(&message.content)
            .bind(&message.citations)
            .bind(&message.model)
            .bind(message.latency_ms)
            .bind(message.created_at)
            .execute(pool)
            .await?;
            outcome.messages_inserted += inserted.rows_affected();
        }
    }

    for belief in &bundle.beliefs {
        let inserted = sqlx::query(
            "INSERT INTO beliefs (id, statement, kind, confidence, stability, corroboration, first_formed, last_confirmed, evidence_episode_ids, counter_evidence_episode_ids, extractor_version, status) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12) ON CONFLICT DO NOTHING",
        )
        .bind(belief.id)
        .bind(&belief.statement)
        .bind(&belief.kind)
        .bind(belief.confidence as f32)
        .bind(belief.stability as f32)
        .bind(&belief.corroboration)
        .bind(belief.first_formed)
        .bind(belief.last_confirmed)
        .bind(&belief.evidence_episode_ids)
        .bind(&belief.counter_evidence_episode_ids)
        .bind(&belief.extractor_version)
        .bind(&belief.status)
        .execute(pool)
        .await?;
        outcome.beliefs_inserted += inserted.rows_affected();
    }
    for belief in &bundle.beliefs {
        if let Some(superseded_by) = belief.superseded_by {
            sqlx::query(
                "UPDATE beliefs SET superseded_by = $2 WHERE id = $1 AND superseded_by IS NULL AND EXISTS (SELECT 1 FROM beliefs b WHERE b.id = $2)",
            )
            .bind(belief.id)
            .bind(superseded_by)
            .execute(pool)
            .await?;
        }
    }

    for claim in &bundle.claims {
        let episode_present =
            sqlx::query_scalar::<_, bool>("SELECT EXISTS (SELECT 1 FROM episodes WHERE id = $1)")
                .bind(claim.episode_id)
                .fetch_one(pool)
                .await?;
        if !episode_present {
            outcome.claims_skipped += 1;
            continue;
        }
        let inserted = sqlx::query(
            "INSERT INTO claims (id, episode_id, statement, subject, predicate, object, asserted_at, hedging, claim_type, testable, expected_observable) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11) ON CONFLICT DO NOTHING",
        )
        .bind(claim.id)
        .bind(claim.episode_id)
        .bind(&claim.statement)
        .bind(&claim.subject)
        .bind(&claim.predicate)
        .bind(&claim.object)
        .bind(claim.asserted_at)
        .bind(&claim.hedging)
        .bind(&claim.claim_type)
        .bind(claim.testable)
        .bind(&claim.expected_observable)
        .execute(pool)
        .await?;
        outcome.claims_inserted += inserted.rows_affected();
    }

    for fact in &bundle.facts {
        let inserted = sqlx::query(
            "INSERT INTO facts (id, subject_id, predicate, object_id, object_literal, valid_from, valid_to, created_at, expired_at, confidence, superseded_by, source_episode_ids, extractor_version) VALUES ($1, $2, $3, $4, $5, $6, $7, coalesce($8, now()), $9, $10, $11, $12, $13) ON CONFLICT DO NOTHING",
        )
        .bind(fact.id)
        .bind(fact.subject_id)
        .bind(&fact.predicate)
        .bind(fact.object_id)
        .bind(&fact.object_literal)
        .bind(fact.valid_from)
        .bind(fact.valid_to)
        .bind(fact.created_at)
        .bind(fact.expired_at)
        .bind(fact.confidence.map(|value| value as f32))
        .bind(fact.superseded_by)
        .bind(&fact.source_episode_ids)
        .bind(&fact.extractor_version)
        .execute(pool)
        .await?;
        outcome.facts_inserted += inserted.rows_affected();
    }

    for section in &bundle.core_memory {
        let inserted = sqlx::query(
            "INSERT INTO core_memory (section, content, updated_by) VALUES ($1, $2, 'import') ON CONFLICT DO NOTHING",
        )
        .bind(&section.section)
        .bind(&section.content)
        .execute(pool)
        .await?;
        outcome.core_sections_inserted += inserted.rows_affected();
    }

    for (key, value) in &bundle.settings {
        if !IMPORTABLE_SETTINGS.contains(&key.as_str()) {
            continue;
        }
        let inserted = sqlx::query(
            "INSERT INTO settings (key, value) VALUES ($1, $2) ON CONFLICT DO NOTHING",
        )
        .bind(key)
        .bind(value)
        .execute(pool)
        .await?;
        outcome.settings_inserted += inserted.rows_affected();
    }

    outcome.pending_episodes = sqlx::query_scalar::<_, i64>(
        "SELECT count(*) FROM episodes e WHERE NOT EXISTS (SELECT 1 FROM chunks c WHERE c.episode_id = e.id)",
    )
    .fetch_one(pool)
    .await?;
    Ok(outcome)
}

pub fn vault_relative(uri: &str) -> Option<PathBuf> {
    let path = Path::new(uri);
    if path.is_absolute() {
        return None;
    }
    let mut clean = PathBuf::new();
    for component in path.components() {
        match component {
            Component::Normal(part) => clean.push(part),
            _ => return None,
        }
    }
    (!clean.as_os_str().is_empty()).then_some(clean)
}

pub async fn import_media(
    pool: &PgPool,
    vault_dir: &Path,
    sha256: &str,
    name: &str,
    bytes: &[u8],
) -> Result<Value, Box<dyn Error + Send + Sync>> {
    let known =
        sqlx::query_scalar::<_, bool>("SELECT EXISTS (SELECT 1 FROM sources WHERE sha256 = $1)")
            .bind(sha256)
            .fetch_one(pool)
            .await?;
    if !known {
        return Err("no source with that sha256; import the bundle first".into());
    }
    let uri = write_vault_file(vault_dir, sha256, name, bytes).await?;
    Ok(json!({"uri": uri, "bytes": bytes.len()}))
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DeleteEpisodeOutcome {
    pub id: Uuid,
    pub claims_deleted: u64,
    pub chunks_deleted: u64,
    pub source_deleted: bool,
    pub vault_file_removed: bool,
}

pub async fn delete_episode(
    pool: &PgPool,
    vault_dir: &Path,
    id: Uuid,
) -> Result<Option<DeleteEpisodeOutcome>, Box<dyn Error + Send + Sync>> {
    let Some((source_id, uri)) = sqlx::query_as::<_, (Uuid, String)>(
        "SELECT s.id, s.uri FROM episodes e JOIN sources s ON s.id = e.source_id WHERE e.id = $1",
    )
    .bind(id)
    .fetch_optional(pool)
    .await?
    else {
        return Ok(None);
    };

    let chunks = sqlx::query_scalar::<_, i64>("SELECT count(*) FROM chunks WHERE episode_id = $1")
        .bind(id)
        .fetch_one(pool)
        .await?;

    let mut transaction = pool.begin().await?;
    sqlx::query(
        "DELETE FROM corroborations WHERE claim_id IN (SELECT id FROM claims WHERE episode_id = $1)",
    )
    .bind(id)
    .execute(&mut *transaction)
    .await?;
    let claims = sqlx::query("DELETE FROM claims WHERE episode_id = $1")
        .bind(id)
        .execute(&mut *transaction)
        .await?;
    sqlx::query("UPDATE open_questions SET answer_episode_id = NULL WHERE answer_episode_id = $1")
        .bind(id)
        .execute(&mut *transaction)
        .await?;
    sqlx::query(
        "UPDATE beliefs SET evidence_episode_ids = array_remove(evidence_episode_ids, $1), counter_evidence_episode_ids = array_remove(counter_evidence_episode_ids, $1) WHERE $1 = ANY(evidence_episode_ids) OR $1 = ANY(counter_evidence_episode_ids)",
    )
    .bind(id)
    .execute(&mut *transaction)
    .await?;
    sqlx::query(
        "UPDATE facts SET source_episode_ids = array_remove(source_episode_ids, $1) WHERE $1 = ANY(source_episode_ids)",
    )
    .bind(id)
    .execute(&mut *transaction)
    .await?;
    sqlx::query("DELETE FROM episodes WHERE id = $1")
        .bind(id)
        .execute(&mut *transaction)
        .await?;
    let orphaned = sqlx::query(
        "DELETE FROM sources WHERE id = $1 AND NOT EXISTS (SELECT 1 FROM episodes WHERE source_id = $1)",
    )
    .bind(source_id)
    .execute(&mut *transaction)
    .await?;
    transaction.commit().await?;

    let source_deleted = orphaned.rows_affected() > 0;
    let mut vault_file_removed = false;
    if source_deleted
        && let Some(relative) = vault_relative(&uri)
    {
        let path = vault_dir.join(&relative);
        if tokio::fs::remove_file(&path).await.is_ok() {
            vault_file_removed = true;
            if let Some(parent) = path.parent() {
                let _ = tokio::fs::remove_dir(parent).await;
            }
        }
    }

    Ok(Some(DeleteEpisodeOutcome {
        id,
        claims_deleted: claims.rows_affected(),
        chunks_deleted: chunks as u64,
        source_deleted,
        vault_file_removed,
    }))
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct WipeOutcome {
    pub episodes_dropped: i64,
    pub sources_dropped: i64,
    pub observations_dropped: i64,
    pub conversations_dropped: i64,
    pub beliefs_dropped: i64,
    pub vault_cleared: bool,
}

const WIPE_SQL: &str = "TRUNCATE TABLE observations, retrievals, turns, signals, corroborations, commitments, discrepancies, calibrations, claims, chunks, entity_mentions, entities, belief_links, beliefs, reflections, facts, core_memory, hypothesis_revisions, predictions, hypotheses, open_questions, muted_topics, persona_lenses, messages, conversations, nightly_runs, episodes, sources CASCADE";

pub async fn wipe(
    pool: &PgPool,
    vault_dir: &Path,
) -> Result<WipeOutcome, Box<dyn Error + Send + Sync>> {
    let (episodes, sources, observations, conversations, beliefs) =
        sqlx::query_as::<_, (i64, i64, i64, i64, i64)>(
            "SELECT (SELECT count(*) FROM episodes), (SELECT count(*) FROM sources), (SELECT count(*) FROM observations), (SELECT count(*) FROM conversations), (SELECT count(*) FROM beliefs)",
        )
        .fetch_one(pool)
        .await?;

    sqlx::query(WIPE_SQL).execute(pool).await?;

    let mut vault_cleared = true;
    for directory in ["objects", "notion"] {
        let path = vault_dir.join(directory);
        match tokio::fs::remove_dir_all(&path).await {
            Ok(()) => {}
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
            Err(_) => vault_cleared = false,
        }
    }

    Ok(WipeOutcome {
        episodes_dropped: episodes,
        sources_dropped: sources,
        observations_dropped: observations,
        conversations_dropped: conversations,
        beliefs_dropped: beliefs,
        vault_cleared,
    })
}

#[cfg(test)]
mod tests {
    use super::{Bundle, FORMAT, VERSION, validate, vault_relative};

    fn bundle(format: &str, version: i64) -> Bundle {
        serde_json::from_value(serde_json::json!({"format": format, "version": version}))
            .expect("a minimal bundle parses")
    }

    #[test]
    fn a_bundle_from_the_future_is_refused() {
        let error = validate(&bundle(FORMAT, VERSION + 1)).unwrap_err();
        assert!(error.contains("update the companion"));
    }

    #[test]
    fn a_foreign_document_is_refused() {
        let error = validate(&bundle("something-else", 1)).unwrap_err();
        assert!(error.contains("not a companion export"));
    }

    #[test]
    fn the_current_format_is_accepted() {
        assert!(validate(&bundle(FORMAT, VERSION)).is_ok());
    }

    #[test]
    fn vault_paths_never_escape_the_vault() {
        assert!(vault_relative("../secrets").is_none());
        assert!(vault_relative("/etc/passwd").is_none());
        assert!(vault_relative("objects/../..").is_none());
        assert!(vault_relative("").is_none());
        assert_eq!(
            vault_relative("objects/ab/abc123/note.md")
                .expect("a normal uri survives")
                .to_string_lossy(),
            "objects/ab/abc123/note.md"
        );
    }

    #[test]
    fn every_bundle_list_defaults_to_empty() {
        let bundle = bundle(FORMAT, VERSION);
        assert!(bundle.episodes.is_empty());
        assert!(bundle.observations.is_empty());
        assert!(bundle.conversations.is_empty());
        assert!(bundle.beliefs.is_empty());
        assert!(bundle.claims.is_empty());
        assert!(bundle.facts.is_empty());
    }
}
