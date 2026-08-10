use std::path::Path;

use chrono::{DateTime, NaiveDate, SecondsFormat, Utc};
use serde::{Serialize, Serializer};
use sha2::{Digest, Sha256};
use sqlx::PgPool;
use uuid::Uuid;

use crate::frontmatter::parse_front_matter;
use crate::lang::{SttRouter, code_switch_points, store_english};
use crate::reason::ReasonClient;
use crate::signals::{Signal, signals_from_segments, store_signals};
use crate::vault::write_vault_file;

#[derive(Debug)]
pub struct IngestFile {
    pub name: String,
    pub text: String,
    pub mtime: Option<String>,
}

#[derive(Debug, Serialize)]
pub struct IngestOutcome {
    pub name: String,
    pub status: &'static str,
    #[serde(rename = "episodeId")]
    pub episode_id: Uuid,
    #[serde(rename = "occurredAt", serialize_with = "serialize_date")]
    pub occurred_at: DateTime<Utc>,
}

fn serialize_date<S>(date: &DateTime<Utc>, serializer: S) -> Result<S::Ok, S::Error>
where
    S: Serializer,
{
    serializer.serialize_str(&date.to_rfc3339_opts(SecondsFormat::AutoSi, true))
}

pub fn parse_file_date(value: &str) -> Option<DateTime<Utc>> {
    if value.len() == 10 {
        if let Ok(date) = NaiveDate::parse_from_str(value, "%Y-%m-%d") {
            return date.and_hms_opt(0, 0, 0).map(|date| date.and_utc());
        }
    }
    DateTime::parse_from_rfc3339(value)
        .ok()
        .map(|date| date.with_timezone(&Utc))
}

fn file_title(name: &str) -> String {
    Path::new(name)
        .file_stem()
        .or_else(|| Path::new(name).file_name())
        .unwrap_or_default()
        .to_string_lossy()
        .into_owned()
}

async fn existing_episode(
    transaction: &mut sqlx::Transaction<'_, sqlx::Postgres>,
    sha256: &str,
) -> Result<Option<(Uuid, DateTime<Utc>)>, sqlx::Error> {
    sqlx::query_as::<_, (Uuid, DateTime<Utc>)>(
        "SELECT e.id, e.occurred_at FROM sources s JOIN episodes e ON e.source_id = s.id WHERE s.sha256 = $1 ORDER BY e.ingested_at LIMIT 1",
    )
    .bind(sha256)
    .fetch_optional(&mut **transaction)
    .await
}

pub async fn ingest_files(
    pool: &PgPool,
    vault_dir: &Path,
    files: Vec<IngestFile>,
) -> Result<Vec<IngestOutcome>, Box<dyn std::error::Error + Send + Sync>> {
    let mut outcomes = Vec::with_capacity(files.len());

    for file in files {
        let sha256 = hex::encode(Sha256::digest(file.text.as_bytes()));
        let mut transaction = pool.begin().await?;

        if let Some((episode_id, occurred_at)) = existing_episode(&mut transaction, &sha256).await?
        {
            transaction.commit().await?;
            outcomes.push(IngestOutcome {
                name: file.name,
                status: "duplicate",
                episode_id,
                occurred_at,
            });
            continue;
        }

        let uri = write_vault_file(vault_dir, &sha256, &file.name, file.text.as_bytes()).await?;
        let source_id = sqlx::query_scalar::<_, Uuid>(
            "INSERT INTO sources (kind, uri, sha256, bytes) VALUES ('md', $1, $2, $3) ON CONFLICT (sha256) DO NOTHING RETURNING id",
        )
        .bind(uri)
        .bind(&sha256)
        .bind(file.text.len() as i64)
        .fetch_optional(&mut *transaction)
        .await?;

        let Some(source_id) = source_id else {
            let raced_episode = existing_episode(&mut transaction, &sha256).await?;
            let Some((episode_id, occurred_at)) = raced_episode else {
                return Err(format!("Source {sha256} exists without an episode").into());
            };
            transaction.commit().await?;
            outcomes.push(IngestOutcome {
                name: file.name,
                status: "duplicate",
                episode_id,
                occurred_at,
            });
            continue;
        };

        let front_matter = parse_front_matter(&file.text);
        let occurred_at = front_matter
            .date
            .or_else(|| file.mtime.as_deref().and_then(parse_file_date))
            .unwrap_or_else(Utc::now);
        let title = front_matter.title.unwrap_or_else(|| file_title(&file.name));
        let (episode_id, occurred_at) = sqlx::query_as::<_, (Uuid, DateTime<Utc>)>(
            "INSERT INTO episodes (source_id, occurred_at, kind, title, body_original, langs) VALUES ($1, $2, 'md', $3, $4, ARRAY['en']::text[]) RETURNING id, occurred_at",
        )
        .bind(source_id)
        .bind(occurred_at)
        .bind(title)
        .bind(&file.text)
        .fetch_one(&mut *transaction)
        .await?;

        transaction.commit().await?;
        outcomes.push(IngestOutcome {
            name: file.name,
            status: "ingested",
            episode_id,
            occurred_at,
        });
    }

    Ok(outcomes)
}

pub async fn ingest_pdf(
    pool: &PgPool,
    vault_dir: &Path,
    name: String,
    bytes: Vec<u8>,
    mtime: Option<String>,
) -> Result<IngestOutcome, Box<dyn std::error::Error + Send + Sync>> {
    let sha256 = hex::encode(Sha256::digest(&bytes));

    {
        let mut transaction = pool.begin().await?;
        if let Some((episode_id, occurred_at)) = existing_episode(&mut transaction, &sha256).await?
        {
            transaction.commit().await?;
            return Ok(IngestOutcome {
                name,
                status: "duplicate",
                episode_id,
                occurred_at,
            });
        }
    }

    let text = pdf_extract::extract_text_from_mem(&bytes)
        .map_err(|error| format!("PDF text extraction failed: {error}"))?;
    let text = text.trim().to_owned();
    if text.is_empty() {
        return Err(
            "PDF contained no extractable text; scanned documents are not supported yet".into(),
        );
    }

    let uri = write_vault_file(vault_dir, &sha256, &name, &bytes).await?;
    let mut transaction = pool.begin().await?;
    let source_id = sqlx::query_scalar::<_, Uuid>(
        "INSERT INTO sources (kind, uri, sha256, bytes) VALUES ('pdf', $1, $2, $3) ON CONFLICT (sha256) DO NOTHING RETURNING id",
    )
    .bind(uri)
    .bind(&sha256)
    .bind(bytes.len() as i64)
    .fetch_optional(&mut *transaction)
    .await?;

    let Some(source_id) = source_id else {
        let raced_episode = existing_episode(&mut transaction, &sha256).await?;
        let Some((episode_id, occurred_at)) = raced_episode else {
            return Err(format!("Source {sha256} exists without an episode").into());
        };
        transaction.commit().await?;
        return Ok(IngestOutcome {
            name,
            status: "duplicate",
            episode_id,
            occurred_at,
        });
    };

    let occurred_at = mtime
        .as_deref()
        .and_then(parse_file_date)
        .unwrap_or_else(Utc::now);
    let title = file_title(&name);
    let (episode_id, occurred_at) = sqlx::query_as::<_, (Uuid, DateTime<Utc>)>(
        "INSERT INTO episodes (source_id, occurred_at, kind, title, body_original, langs) VALUES ($1, $2, 'pdf', $3, $4, ARRAY['en']::text[]) RETURNING id, occurred_at",
    )
    .bind(source_id)
    .bind(occurred_at)
    .bind(title)
    .bind(&text)
    .fetch_one(&mut *transaction)
    .await?;

    transaction.commit().await?;
    Ok(IngestOutcome {
        name,
        status: "ingested",
        episode_id,
        occurred_at,
    })
}

pub async fn ingest_audio(
    pool: &PgPool,
    vault_dir: &Path,
    stt: &SttRouter,
    reason: &ReasonClient,
    name: String,
    bytes: Vec<u8>,
    mtime: Option<String>,
) -> Result<IngestOutcome, Box<dyn std::error::Error + Send + Sync>> {
    let sha256 = hex::encode(Sha256::digest(&bytes));

    {
        let mut transaction = pool.begin().await?;
        if let Some((episode_id, occurred_at)) = existing_episode(&mut transaction, &sha256).await?
        {
            transaction.commit().await?;
            return Ok(IngestOutcome {
                name,
                status: "duplicate",
                episode_id,
                occurred_at,
            });
        }
    }

    let (transcript, read, route) = stt.transcribe(&name, bytes.clone()).await?;
    let uri = write_vault_file(vault_dir, &sha256, &name, &bytes).await?;
    let duration = transcript.duration.or_else(|| {
        transcript
            .segments
            .last()
            .map(|segment| segment.end)
            .filter(|end| *end > 0.0)
    });
    let segments = transcript
        .segments
        .iter()
        .map(|segment| {
            serde_json::json!({
                "start": segment.start,
                "end": segment.end,
                "text": segment.text.trim(),
            })
        })
        .collect::<Vec<_>>();
    let langs = read.langs.clone();

    let mut transaction = pool.begin().await?;
    let source_id = sqlx::query_scalar::<_, Uuid>(
        "INSERT INTO sources (kind, uri, sha256, bytes) VALUES ('voice', $1, $2, $3) ON CONFLICT (sha256) DO NOTHING RETURNING id",
    )
    .bind(uri)
    .bind(&sha256)
    .bind(bytes.len() as i64)
    .fetch_optional(&mut *transaction)
    .await?;

    let Some(source_id) = source_id else {
        let raced_episode = existing_episode(&mut transaction, &sha256).await?;
        let Some((episode_id, occurred_at)) = raced_episode else {
            return Err(format!("Source {sha256} exists without an episode").into());
        };
        transaction.commit().await?;
        return Ok(IngestOutcome {
            name,
            status: "duplicate",
            episode_id,
            occurred_at,
        });
    };

    let occurred_at = mtime
        .as_deref()
        .and_then(parse_file_date)
        .unwrap_or_else(Utc::now);
    let title = file_title(&name);
    let (episode_id, occurred_at) = sqlx::query_as::<_, (Uuid, DateTime<Utc>)>(
        "INSERT INTO episodes (source_id, occurred_at, kind, title, body_original, langs, media_ref, duration_s, meta, script) VALUES ($1, $2, 'voice', $3, $4, $5, $6, $7, $8, $9) RETURNING id, occurred_at",
    )
    .bind(source_id)
    .bind(occurred_at)
    .bind(title)
    .bind(transcript.text.trim())
    .bind(&langs)
    .bind(format!("vault:{sha256}"))
    .bind(duration)
    .bind(serde_json::json!({
        "segments": segments,
        "sttRoute": route,
        "sttReported": transcript.language,
        "context": "voice",
    }))
    .bind(&read.script)
    .fetch_one(&mut *transaction)
    .await?;

    transaction.commit().await?;
    let mut signals = signals_from_segments(&transcript.segments, duration);
    let spans = transcript
        .segments
        .iter()
        .map(|segment| (segment.start, segment.end, segment.text.clone()))
        .collect::<Vec<_>>();
    for (start, end) in code_switch_points(&spans) {
        signals.push(Signal {
            t_start_s: start,
            t_end_s: end,
            kind: "code_switch",
            value: 1.0,
        });
    }
    store_signals(pool, episode_id, &signals).await?;
    store_english(
        pool,
        reason,
        episode_id,
        transcript.text.trim(),
        &read,
    )
    .await;
    Ok(IngestOutcome {
        name,
        status: "ingested",
        episode_id,
        occurred_at,
    })
}
