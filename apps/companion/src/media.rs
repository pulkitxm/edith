use std::error::Error;
use std::path::{Path, PathBuf};

use chrono::{DateTime, Utc};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use sqlx::PgPool;
use tokio::process::Command;
use uuid::Uuid;

use crate::ingest::{IngestOutcome, parse_file_date};
use crate::lang::{SttRouter, store_english};
use crate::reason::ReasonClient;
use crate::signals::{signals_from_segments, store_signals};
use crate::vault::write_vault_file;
use crate::vision::{Exif, VisionClient, exif_from_json};

pub const MAX_KEYFRAMES: usize = 200;
pub const MIN_KEYFRAME_GAP_S: f64 = 10.0;
pub const SCENE_THRESHOLD: f64 = 0.4;

pub fn image_extensions() -> [&'static str; 7] {
    ["jpg", "jpeg", "png", "heic", "heif", "webp", "gif"]
}

pub fn video_extensions() -> [&'static str; 6] {
    ["mp4", "mov", "m4v", "mkv", "webm", "avi"]
}

pub fn kind_for(name: &str) -> Option<&'static str> {
    let extension = Path::new(name)
        .extension()
        .map(|value| value.to_string_lossy().to_lowercase())?;
    if image_extensions().contains(&extension.as_str()) {
        return Some("image");
    }
    if video_extensions().contains(&extension.as_str()) {
        return Some("video");
    }
    None
}

pub fn title_for(name: &str) -> String {
    Path::new(name)
        .file_stem()
        .map(|stem| stem.to_string_lossy().into_owned())
        .unwrap_or_else(|| name.to_owned())
}

pub fn album_of(name: &str) -> Option<String> {
    Path::new(name)
        .parent()
        .and_then(|parent| parent.file_name())
        .map(|album| album.to_string_lossy().into_owned())
        .filter(|album| !album.is_empty() && album != "." && album != "/")
}

pub fn thin_keyframes(times: &[f64]) -> Vec<f64> {
    let mut kept: Vec<f64> = Vec::new();
    for time in times {
        if kept
            .last()
            .is_none_or(|last| time - last >= MIN_KEYFRAME_GAP_S)
        {
            kept.push(*time);
        }
        if kept.len() >= MAX_KEYFRAMES {
            break;
        }
    }
    kept
}

pub fn parse_scene_times(output: &str) -> Vec<f64> {
    output
        .lines()
        .filter_map(|line| {
            let start = line.find("pts_time:")? + "pts_time:".len();
            line[start..]
                .split_whitespace()
                .next()?
                .parse::<f64>()
                .ok()
        })
        .collect()
}

async fn probe_duration(path: &Path) -> Option<f32> {
    let output = Command::new("ffprobe")
        .args([
            "-v",
            "error",
            "-show_entries",
            "format=duration",
            "-of",
            "default=noprint_wrappers=1:nokey=1",
        ])
        .arg(path)
        .output()
        .await
        .ok()?;
    String::from_utf8_lossy(&output.stdout)
        .trim()
        .parse::<f32>()
        .ok()
}

pub async fn exif_of(path: &Path, album: Option<String>) -> Exif {
    let Ok(output) = Command::new("exiftool")
        .args(["-json", "-n", "-DateTimeOriginal", "-GPSLatitude", "-GPSLongitude", "-Model"])
        .arg(path)
        .output()
        .await
    else {
        return Exif {
            album,
            ..Exif::default()
        };
    };
    let parsed = serde_json::from_slice::<Value>(&output.stdout)
        .ok()
        .and_then(|value| value.as_array().and_then(|items| items.first().cloned()));
    match parsed {
        Some(value) => exif_from_json(&value, album),
        None => Exif {
            album,
            ..Exif::default()
        },
    }
}

pub async fn tooling_check() -> Result<String, String> {
    let mut found = Vec::new();
    for tool in ["ffmpeg", "ffprobe", "exiftool"] {
        let ok = Command::new(tool)
            .arg("-version")
            .output()
            .await
            .is_ok_and(|output| output.status.success());
        if ok {
            found.push(tool);
        }
    }
    if found.contains(&"ffmpeg") && found.contains(&"ffprobe") {
        Ok(format!("{} available", found.join(", ")))
    } else {
        Err(format!(
            "video needs ffmpeg and ffprobe; found {}",
            if found.is_empty() {
                "none".to_owned()
            } else {
                found.join(", ")
            }
        ))
    }
}

async fn existing(pool: &PgPool, sha256: &str) -> Result<Option<(Uuid, DateTime<Utc>)>, sqlx::Error> {
    sqlx::query_as::<_, (Uuid, DateTime<Utc>)>(
        "SELECT e.id, e.occurred_at FROM sources s JOIN episodes e ON e.source_id = s.id WHERE s.sha256 = $1 ORDER BY e.ingested_at LIMIT 1",
    )
    .bind(sha256)
    .fetch_optional(pool)
    .await
}

type Ingested = Result<IngestOutcome, Box<dyn Error + Send + Sync>>;

pub async fn ingest_image(
    pool: &PgPool,
    vault_dir: &Path,
    vision: &VisionClient,
    name: String,
    bytes: Vec<u8>,
    mtime: Option<String>,
) -> Ingested {
    let sha256 = hex::encode(Sha256::digest(&bytes));
    if let Some((episode_id, occurred_at)) = existing(pool, &sha256).await? {
        return Ok(IngestOutcome {
            name,
            status: "duplicate",
            episode_id,
            occurred_at,
        });
    }

    let uri = write_vault_file(vault_dir, &sha256, &name, &bytes).await?;
    let stored = vault_path(vault_dir, &uri);
    let exif = exif_of(&stored, album_of(&name)).await;
    let caption = vision.caption(&bytes, &exif).await?;

    let occurred_at = exif
        .taken_at
        .as_deref()
        .and_then(parse_file_date)
        .or_else(|| mtime.as_deref().and_then(parse_file_date))
        .unwrap_or_else(Utc::now);
    let body = format!("{caption}\n\nCapture details: {}", exif.prompt_line());

    let source_id = sqlx::query_scalar::<_, Uuid>(
        "INSERT INTO sources (kind, uri, sha256, bytes) VALUES ('image', $1, $2, $3) RETURNING id",
    )
    .bind(&uri)
    .bind(&sha256)
    .bind(bytes.len() as i64)
    .fetch_one(pool)
    .await?;
    let (episode_id, occurred_at) = sqlx::query_as::<_, (Uuid, DateTime<Utc>)>(
        "INSERT INTO episodes (source_id, occurred_at, kind, title, body_original, body_en, langs, script, media_ref, meta) VALUES ($1, $2, 'image', $3, $4, $4, '{en}', 'latn', $5, $6) RETURNING id, occurred_at",
    )
    .bind(source_id)
    .bind(occurred_at)
    .bind(title_for(&name))
    .bind(&body)
    .bind(format!("vault:{sha256}"))
    .bind(json!({
        "exif": exif,
        "captioner": vision.model(),
        "context": "image",
    }))
    .fetch_one(pool)
    .await?;

    Ok(IngestOutcome {
        name,
        status: "ingested",
        episode_id,
        occurred_at,
    })
}

fn vault_path(vault_dir: &Path, uri: &str) -> PathBuf {
    match uri.strip_prefix("file://") {
        Some(path) => PathBuf::from(path),
        None => vault_dir.join(uri),
    }
}

pub struct VideoDeps<'a> {
    pub pool: &'a PgPool,
    pub vault_dir: &'a Path,
    pub stt: &'a SttRouter,
    pub vision: &'a VisionClient,
    pub reason: &'a ReasonClient,
}

pub async fn ingest_video(
    deps: &VideoDeps<'_>,
    name: String,
    bytes: Vec<u8>,
    mtime: Option<String>,
) -> Ingested {
    let sha256 = hex::encode(Sha256::digest(&bytes));
    if let Some((episode_id, occurred_at)) = existing(deps.pool, &sha256).await? {
        return Ok(IngestOutcome {
            name,
            status: "duplicate",
            episode_id,
            occurred_at,
        });
    }
    tooling_check().await.map_err(|detail| -> Box<dyn Error + Send + Sync> { detail.into() })?;

    let uri = write_vault_file(deps.vault_dir, &sha256, &name, &bytes).await?;
    let stored = vault_path(deps.vault_dir, &uri);
    let duration = probe_duration(&stored).await;

    let work = std::env::temp_dir().join(format!("companion-video-{sha256}"));
    tokio::fs::create_dir_all(&work).await?;
    let audio_path = work.join("audio.wav");
    let audio_ok = Command::new("ffmpeg")
        .args(["-nostdin", "-y", "-i"])
        .arg(&stored)
        .args(["-vn", "-ac", "1", "-ar", "16000"])
        .arg(&audio_path)
        .output()
        .await
        .is_ok_and(|output| output.status.success());

    let mut transcript_text = String::new();
    let mut segments = Vec::new();
    let mut langs = vec!["en".to_owned()];
    let mut script = "latn".to_owned();
    let mut read = None;
    if audio_ok && let Ok(audio) = tokio::fs::read(&audio_path).await {
        match deps.stt.transcribe("audio.wav", audio).await {
            Ok((transcript, language, _route)) => {
                transcript_text = transcript.text.trim().to_owned();
                segments = transcript.segments;
                langs = language.langs.clone();
                script = language.script.clone();
                read = Some(language);
            }
            Err(error) => eprintln!("video audio transcription failed: {error}"),
        }
    }

    let keyframes = keyframe_captions(deps, &stored, &work).await;
    let _ = tokio::fs::remove_dir_all(&work).await;

    let mut body = String::new();
    if transcript_text.is_empty() {
        body.push_str("This clip has no speech that could be transcribed.");
    } else {
        body.push_str(&transcript_text);
    }
    if !keyframes.is_empty() {
        body.push_str("\n\nWhat is on screen:\n");
        for (time, caption) in &keyframes {
            body.push_str(&format!("[{:.0}s] {caption}\n", time));
        }
    }

    let occurred_at = mtime
        .as_deref()
        .and_then(parse_file_date)
        .unwrap_or_else(Utc::now);
    let source_id = sqlx::query_scalar::<_, Uuid>(
        "INSERT INTO sources (kind, uri, sha256, bytes) VALUES ('video', $1, $2, $3) RETURNING id",
    )
    .bind(&uri)
    .bind(&sha256)
    .bind(bytes.len() as i64)
    .fetch_one(deps.pool)
    .await?;
    let (episode_id, occurred_at) = sqlx::query_as::<_, (Uuid, DateTime<Utc>)>(
        "INSERT INTO episodes (source_id, occurred_at, kind, title, body_original, langs, script, media_ref, duration_s, meta) VALUES ($1, $2, 'video', $3, $4, $5, $6, $7, $8, $9) RETURNING id, occurred_at",
    )
    .bind(source_id)
    .bind(occurred_at)
    .bind(title_for(&name))
    .bind(&body)
    .bind(&langs)
    .bind(&script)
    .bind(format!("vault:{sha256}"))
    .bind(duration)
    .bind(json!({
        "segments": segments.iter().map(|segment| json!({
            "start": segment.start,
            "end": segment.end,
            "text": segment.text.trim(),
        })).collect::<Vec<_>>(),
        "keyframes": keyframes.iter().map(|(time, caption)| json!({
            "tS": time,
            "caption": caption,
        })).collect::<Vec<_>>(),
        "context": "video",
    }))
    .fetch_one(deps.pool)
    .await?;

    let signals = signals_from_segments(&segments, duration);
    store_signals(deps.pool, episode_id, &signals).await?;
    if let Some(read) = read {
        store_english(deps.pool, deps.reason, episode_id, &body, &read).await;
    }

    Ok(IngestOutcome {
        name,
        status: "ingested",
        episode_id,
        occurred_at,
    })
}

async fn keyframe_captions(
    deps: &VideoDeps<'_>,
    stored: &Path,
    work: &Path,
) -> Vec<(f64, String)> {
    let detect = Command::new("ffmpeg")
        .args(["-nostdin", "-i"])
        .arg(stored)
        .args([
            "-filter_complex",
            &format!("select='gt(scene,{SCENE_THRESHOLD})',metadata=print"),
            "-an",
            "-f",
            "null",
            "-",
        ])
        .output()
        .await;
    let Ok(detect) = detect else {
        return Vec::new();
    };
    let times = thin_keyframes(&parse_scene_times(&String::from_utf8_lossy(&detect.stderr)));

    let mut captions = Vec::new();
    for (index, time) in times.iter().enumerate() {
        let frame = work.join(format!("frame-{index}.jpg"));
        let extracted = Command::new("ffmpeg")
            .args(["-nostdin", "-y", "-ss", &format!("{time}"), "-i"])
            .arg(stored)
            .args(["-frames:v", "1", "-q:v", "3"])
            .arg(&frame)
            .output()
            .await
            .is_ok_and(|output| output.status.success());
        if !extracted {
            continue;
        }
        let Ok(bytes) = tokio::fs::read(&frame).await else {
            continue;
        };
        let exif = Exif {
            taken_at: Some(format!("{time:.0} seconds into the clip")),
            ..Exif::default()
        };
        match deps.vision.caption(&bytes, &exif).await {
            Ok(caption) => captions.push((*time, caption)),
            Err(error) => eprintln!("keyframe caption failed: {error}"),
        }
    }
    captions
}

#[cfg(test)]
mod tests {
    use super::{album_of, kind_for, parse_scene_times, thin_keyframes, MAX_KEYFRAMES};

    #[test]
    fn media_is_routed_by_extension() {
        assert_eq!(kind_for("holiday.HEIC"), Some("image"));
        assert_eq!(kind_for("demo.mp4"), Some("video"));
        assert_eq!(kind_for("notes.md"), None);
    }

    #[test]
    fn the_containing_folder_becomes_the_album() {
        assert_eq!(album_of("/photos/Goa/img.jpg"), Some("Goa".to_owned()));
        assert_eq!(album_of("img.jpg"), None);
    }

    #[test]
    fn scene_times_are_read_out_of_ffmpeg_output() {
        let output = "frame:0 pts:0 pts_time:0\nlavfi.scene_score=0.6\nframe:1 pts_time:12.5\n";
        assert_eq!(parse_scene_times(output), vec![0.0, 12.5]);
    }

    #[test]
    fn keyframes_thin_to_one_every_ten_seconds() {
        let times = vec![0.0, 2.0, 4.0, 11.0, 12.0, 30.0];
        assert_eq!(thin_keyframes(&times), vec![0.0, 11.0, 30.0]);
    }

    #[test]
    fn a_shaky_clip_cannot_flood_the_queue() {
        let times = (0..5000).map(|index| index as f64 * 11.0).collect::<Vec<_>>();
        assert_eq!(thin_keyframes(&times).len(), MAX_KEYFRAMES);
    }
}
