use std::env;

use sqlx::PgPool;
use uuid::Uuid;

use crate::reason::ReasonClient;
use crate::stt::{SttClient, Transcript, SttError};

const HINGLISH_MARKERS: [&str; 24] = [
    "hai", "nahi", "kya", "mera", "meri", "tha", "thi", "kar", "karna", "raha", "rahi", "bhi",
    "toh", "aur", "matlab", "yaar", "acha", "theek", "kuch", "bohot", "bahut", "abhi", "phir",
    "lekin",
];

pub const NORMALIZE_PROMPT: &str = "You render one person's own words into plain English so they \
can be indexed. Translate Hindi and Hinglish into English, keep English as it is, and change \
nothing about what was said: no summarising, no tidying, no adding. Where a word does not \
survive translation, keep it as they said it and put a short gloss in brackets after it. Answer \
with the English text alone.";

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct LanguageRead {
    pub langs: Vec<String>,
    pub script: String,
    pub route: &'static str,
}

pub fn devanagari_ratio(text: &str) -> f32 {
    let letters = text.chars().filter(|c| c.is_alphabetic()).count();
    if letters == 0 {
        return 0.0;
    }
    let deva = text
        .chars()
        .filter(|c| ('\u{0900}'..='\u{097F}').contains(c))
        .count();
    deva as f32 / letters as f32
}

pub fn romanized_hindi_ratio(text: &str) -> f32 {
    let words = text
        .split(|c: char| !c.is_alphanumeric())
        .filter(|word| !word.is_empty())
        .collect::<Vec<_>>();
    if words.is_empty() {
        return 0.0;
    }
    let hits = words
        .iter()
        .filter(|word| HINGLISH_MARKERS.contains(&word.to_lowercase().as_str()))
        .count();
    hits as f32 / words.len() as f32
}

pub fn identify(text: &str, reported: Option<&str>) -> LanguageRead {
    let deva = devanagari_ratio(text);
    let roman = romanized_hindi_ratio(text);
    let reported_hindi = reported.is_some_and(|value| value.starts_with("hi"));

    let script = match deva {
        ratio if ratio > 0.85 => "deva",
        ratio if ratio > 0.05 => "mixed",
        _ => "latn",
    };
    let hindi = deva > 0.05 || roman >= 0.06 || reported_hindi;
    let english = deva < 0.85 && (roman < 0.6 || script != "deva");

    let mut langs = Vec::new();
    if english {
        langs.push("en".to_owned());
    }
    if hindi {
        langs.push("hi".to_owned());
    }
    if langs.is_empty() {
        langs.push(reported.unwrap_or("en").to_owned());
    }

    LanguageRead {
        route: if hindi { "quality" } else { "fast" },
        langs,
        script: script.to_owned(),
    }
}

pub fn needs_english(read: &LanguageRead) -> bool {
    read.langs.iter().any(|lang| lang != "en")
}

#[derive(Clone)]
pub struct SttRouter {
    fast: SttClient,
    quality: SttClient,
}

impl SttRouter {
    pub fn from_env(fast: SttClient) -> Self {
        let quality = match env::var("STT_QUALITY_URL") {
            Ok(url) if !url.trim().is_empty() => SttClient::at(url.trim()),
            _ => fast.clone(),
        };
        Self {
            fast,
            quality,
        }
    }

    pub fn fast(&self) -> &SttClient {
        &self.fast
    }

    pub fn quality(&self) -> &SttClient {
        &self.quality
    }

    pub fn split(&self) -> bool {
        self.fast.base_url() != self.quality.base_url()
    }

    pub fn describe(&self) -> String {
        if self.split() {
            format!(
                "english to {}, hindi and hinglish to {}",
                self.fast.base_url(),
                self.quality.base_url()
            )
        } else {
            format!("one endpoint for every language at {}", self.fast.base_url())
        }
    }

    pub async fn transcribe(
        &self,
        name: &str,
        bytes: Vec<u8>,
    ) -> Result<(Transcript, LanguageRead, &'static str), SttError> {
        let first = self.fast.transcribe(name, bytes.clone()).await?;
        let read = identify(&first.text, first.language.as_deref());
        if read.route == "fast" || !self.split() {
            return Ok((first, read, "fast"));
        }
        let second = self.quality.transcribe(name, bytes).await?;
        let read = identify(&second.text, second.language.as_deref());
        Ok((second, read, "quality"))
    }
}

pub async fn store_english(
    pool: &PgPool,
    reason: &ReasonClient,
    episode_id: Uuid,
    body: &str,
    read: &LanguageRead,
) {
    let english = if needs_english(read) && reason.configured() {
        match reason.complete(NORMALIZE_PROMPT, body).await {
            Ok(translated) if !translated.trim().is_empty() => Some(translated.trim().to_owned()),
            _ => None,
        }
    } else {
        Some(body.to_owned())
    };
    let Some(english) = english else {
        return;
    };
    let translated_by = if needs_english(read) {
        Some(format!("{}, {NORMALIZE_PROMPT_VERSION}", reason.describe()))
    } else {
        None
    };
    let _ = sqlx::query(
        "UPDATE episodes SET body_en = $2, translated_by = $3, langs = $4, script = $5 WHERE id = $1",
    )
    .bind(episode_id)
    .bind(&english)
    .bind(translated_by)
    .bind(&read.langs)
    .bind(&read.script)
    .execute(pool)
    .await;
}

pub const NORMALIZE_PROMPT_VERSION: &str = "normalize-v1";

pub fn code_switch_points(segments: &[(f32, f32, String)]) -> Vec<(f32, f32)> {
    let mut switches = Vec::new();
    let mut previous: Option<bool> = None;
    for (start, end, text) in segments {
        let hindi = devanagari_ratio(text) > 0.05 || romanized_hindi_ratio(text) >= 0.06;
        if previous.is_some_and(|was| was != hindi) {
            switches.push((*start, *end));
        }
        previous = Some(hindi);
    }
    switches
}

#[cfg(test)]
mod tests {
    use super::{code_switch_points, identify, needs_english};

    #[test]
    fn plain_english_routes_to_the_fast_path() {
        let read = identify("I shipped the auth refactor this week and felt fine", None);
        assert_eq!(read.route, "fast");
        assert_eq!(read.langs, vec!["en"]);
        assert_eq!(read.script, "latn");
        assert!(!needs_english(&read));
    }

    #[test]
    fn devanagari_routes_to_the_quality_path() {
        let read = identify("मैं आज बहुत थक गया हूँ", None);
        assert_eq!(read.route, "quality");
        assert_eq!(read.script, "deva");
        assert!(read.langs.contains(&"hi".to_owned()));
        assert!(needs_english(&read));
    }

    #[test]
    fn romanized_hinglish_is_caught_without_devanagari() {
        let read = identify(
            "matlab yaar the deploy toh nahi hua but I think it is fine",
            None,
        );
        assert_eq!(read.route, "quality");
        assert!(read.langs.contains(&"hi".to_owned()));
        assert!(read.langs.contains(&"en".to_owned()));
    }

    #[test]
    fn what_whisper_reports_still_counts() {
        let read = identify("theek", Some("hi"));
        assert_eq!(read.route, "quality");
    }

    #[test]
    fn switching_language_mid_recording_is_a_point_in_time() {
        let segments = vec![
            (0.0, 4.0, "the release went out on tuesday".to_owned()),
            (4.0, 8.0, "मतलब घर पर सब ठीक नहीं है".to_owned()),
            (8.0, 12.0, "anyway back to the work".to_owned()),
        ];
        let switches = code_switch_points(&segments);
        assert_eq!(switches.len(), 2);
        assert_eq!(switches[0].0, 4.0);
    }
}
