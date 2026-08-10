use std::error::Error;

use chrono::{DateTime, Utc};
use serde::Serialize;
use serde_json::{Value, json};
use sqlx::PgPool;

pub const SOURCES: [&str; 5] = ["github", "notion", "calendar", "music", "youtube"];

#[derive(Debug, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ImportOutcome {
    pub source: String,
    pub entries_read: usize,
    pub observations_inserted: usize,
    pub skipped: usize,
}

pub struct Pending {
    pub dedupe_key: String,
    pub kind: String,
    pub observed_at: DateTime<Utc>,
    pub payload: Value,
}

pub async fn store(
    pool: &PgPool,
    source: &str,
    pending: &[Pending],
) -> Result<usize, sqlx::Error> {
    let mut inserted = 0;
    for entry in pending {
        let written = sqlx::query_scalar::<_, i32>(
            "INSERT INTO observations (source, observed_at, kind, payload, dedupe_key) VALUES ($1, $2, $3, $4, $5) ON CONFLICT (dedupe_key) WHERE dedupe_key IS NOT NULL DO NOTHING RETURNING 1",
        )
        .bind(source)
        .bind(entry.observed_at)
        .bind(&entry.kind)
        .bind(&entry.payload)
        .bind(&entry.dedupe_key)
        .fetch_optional(pool)
        .await?;
        if written.is_some() {
            inserted += 1;
        }
    }
    Ok(inserted)
}

fn date_of(value: &Value, keys: &[&str]) -> Option<DateTime<Utc>> {
    for key in keys {
        if let Some(text) = value.get(*key).and_then(Value::as_str)
            && let Some(parsed) = crate::ingest::parse_file_date(text)
        {
            return Some(parsed);
        }
        if let Some(nested) = value.get(*key).and_then(|nested| nested.get("dateTime"))
            && let Some(text) = nested.as_str()
            && let Some(parsed) = crate::ingest::parse_file_date(text)
        {
            return Some(parsed);
        }
    }
    None
}

fn text_of(value: &Value, keys: &[&str]) -> Option<String> {
    keys.iter().find_map(|key| {
        value
            .get(*key)
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|text| !text.is_empty())
            .map(str::to_owned)
    })
}

pub fn calendar_observations(entries: &[Value]) -> Vec<Pending> {
    let mut pending = Vec::new();
    for entry in entries {
        let Some(observed_at) = date_of(entry, &["start", "startDate", "date", "occurredAt"])
        else {
            continue;
        };
        let title = text_of(entry, &["title", "summary", "name"]).unwrap_or_default();
        let end = date_of(entry, &["end", "endDate"]);
        let minutes = end.map(|end| (end - observed_at).num_minutes().max(0));
        let attendees = entry
            .get("attendees")
            .and_then(Value::as_array)
            .map(|items| items.len())
            .unwrap_or(0);
        let moved = entry
            .get("rescheduled")
            .and_then(Value::as_bool)
            .unwrap_or(false);
        pending.push(Pending {
            dedupe_key: format!(
                "calendar:{}:{}",
                observed_at.timestamp(),
                title.to_lowercase()
            ),
            kind: if moved {
                "meeting_moved".to_owned()
            } else {
                "meeting".to_owned()
            },
            observed_at,
            payload: json!({
                "title": title,
                "minutes": minutes,
                "attendees": attendees,
                "rescheduled": moved,
            }),
        });
    }
    pending
}

pub fn music_observations(entries: &[Value]) -> Vec<Pending> {
    let mut pending = Vec::new();
    for entry in entries {
        let Some(observed_at) = date_of(entry, &["playedAt", "date", "uts", "occurredAt"]) else {
            continue;
        };
        let track = text_of(entry, &["track", "name", "title"]).unwrap_or_default();
        let artist = text_of(entry, &["artist", "artistName"]).unwrap_or_default();
        let album = text_of(entry, &["album", "albumName"]).unwrap_or_default();
        if track.is_empty() {
            continue;
        }
        pending.push(Pending {
            dedupe_key: format!(
                "music:{}:{}",
                observed_at.timestamp(),
                track.to_lowercase()
            ),
            kind: "play".to_owned(),
            observed_at,
            payload: json!({
                "track": track,
                "artist": artist,
                "album": album,
                "hour": observed_at.format("%H").to_string(),
            }),
        });
    }
    pending
}

pub fn youtube_observations(entries: &[Value]) -> Vec<Pending> {
    let mut pending = Vec::new();
    for entry in entries {
        let Some(observed_at) = date_of(entry, &["time", "watchedAt", "date"]) else {
            continue;
        };
        let title = text_of(entry, &["title"])
            .map(|title| {
                title
                    .trim_start_matches("Watched ")
                    .trim_start_matches("Viewed ")
                    .to_owned()
            })
            .unwrap_or_default();
        if title.is_empty() {
            continue;
        }
        let channel = entry
            .get("subtitles")
            .and_then(Value::as_array)
            .and_then(|items| items.first())
            .and_then(|item| item.get("name"))
            .and_then(Value::as_str)
            .or_else(|| entry.get("channel").and_then(Value::as_str))
            .unwrap_or_default()
            .to_owned();
        pending.push(Pending {
            dedupe_key: format!(
                "youtube:{}:{}",
                observed_at.timestamp(),
                title.to_lowercase()
            ),
            kind: "watch".to_owned(),
            observed_at,
            payload: json!({
                "title": title,
                "channel": channel,
                "hour": observed_at.format("%H").to_string(),
                "lateNight": matches!(
                    observed_at.format("%H").to_string().as_str(),
                    "00" | "01" | "02" | "03" | "04"
                ),
            }),
        });
    }
    pending
}

pub fn observations_for(source: &str, entries: &[Value]) -> Result<Vec<Pending>, String> {
    match source {
        "calendar" => Ok(calendar_observations(entries)),
        "music" => Ok(music_observations(entries)),
        "youtube" => Ok(youtube_observations(entries)),
        other => Err(format!(
            "{other} is not an importable connector; the importable ones are calendar, music and youtube"
        )),
    }
}

pub fn entries_of(body: &Value) -> Vec<Value> {
    if let Some(array) = body.as_array() {
        return array.clone();
    }
    for key in ["entries", "events", "items", "tracks", "recenttracks"] {
        if let Some(array) = body.get(key).and_then(Value::as_array) {
            return array.clone();
        }
        if let Some(nested) = body.get(key).and_then(|nested| nested.get("track"))
            && let Some(array) = nested.as_array()
        {
            return array.clone();
        }
    }
    Vec::new()
}

pub async fn import(
    pool: &PgPool,
    source: &str,
    body: &Value,
) -> Result<ImportOutcome, Box<dyn Error + Send + Sync>> {
    let entries = entries_of(body);
    let pending = observations_for(source, &entries)?;
    let inserted = store(pool, source, &pending).await?;
    Ok(ImportOutcome {
        source: source.to_owned(),
        entries_read: entries.len(),
        skipped: entries.len().saturating_sub(pending.len()),
        observations_inserted: inserted,
    })
}

pub async fn record_usage(
    pool: &PgPool,
    kind: &str,
    payload: &Value,
    observed_at: DateTime<Utc>,
) -> Result<bool, sqlx::Error> {
    let inserted = sqlx::query_scalar::<_, i32>(
        "INSERT INTO observations (source, observed_at, kind, payload, dedupe_key) VALUES ('edith', $1, $2, $3, $4) ON CONFLICT (dedupe_key) WHERE dedupe_key IS NOT NULL DO NOTHING RETURNING 1",
    )
    .bind(observed_at)
    .bind(kind)
    .bind(payload)
    .bind(format!("edith:{kind}:{}", observed_at.timestamp()))
    .fetch_optional(pool)
    .await?;
    Ok(inserted.is_some())
}

#[cfg(test)]
mod tests {
    use super::{
        calendar_observations, entries_of, music_observations, observations_for,
        youtube_observations,
    };
    use serde_json::json;

    #[test]
    fn a_rescheduled_meeting_is_its_own_kind() {
        let entries = vec![json!({
            "title": "Design review",
            "start": "2026-08-01T10:00:00Z",
            "end": "2026-08-01T11:00:00Z",
            "rescheduled": true,
            "attendees": [{"name": "a"}, {"name": "b"}],
        })];
        let pending = calendar_observations(&entries);
        assert_eq!(pending.len(), 1);
        assert_eq!(pending[0].kind, "meeting_moved");
        assert_eq!(pending[0].payload["minutes"], 60);
        assert_eq!(pending[0].payload["attendees"], 2);
    }

    #[test]
    fn plays_carry_the_hour_rather_than_a_mood() {
        let entries = vec![json!({
            "track": "Teardrop", "artist": "Massive Attack",
            "playedAt": "2026-08-01T23:40:00Z",
        })];
        let pending = music_observations(&entries);
        assert_eq!(pending[0].payload["hour"], "23");
        assert!(pending[0].payload.get("valence").is_none());
        assert!(pending[0].payload.get("mood").is_none());
    }

    #[test]
    fn takeout_watch_history_reads_the_channel_and_the_hour() {
        let entries = vec![json!({
            "title": "Watched Some deep dive",
            "time": "2026-08-02T02:10:00Z",
            "subtitles": [{"name": "A Channel"}],
        })];
        let pending = youtube_observations(&entries);
        assert_eq!(pending[0].payload["title"], "Some deep dive");
        assert_eq!(pending[0].payload["channel"], "A Channel");
        assert_eq!(pending[0].payload["lateNight"], true);
    }

    #[test]
    fn entries_are_found_however_the_export_wraps_them() {
        assert_eq!(entries_of(&json!([{"a": 1}])).len(), 1);
        assert_eq!(entries_of(&json!({"events": [{"a": 1}]})).len(), 1);
        assert_eq!(entries_of(&json!({"nothing": 1})).len(), 0);
    }

    #[test]
    fn an_unknown_connector_is_refused_by_name() {
        assert!(observations_for("strava", &[]).is_err());
    }
}
