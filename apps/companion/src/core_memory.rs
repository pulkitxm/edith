use std::error::Error;

use chrono::{DateTime, Utc};
use serde::Serialize;
use serde_json::Value;
use sqlx::PgPool;
use uuid::Uuid;

use crate::reason::{ReasonClient, ReasonError};

pub const SECTIONS: [&str; 6] = [
    "identity",
    "current_situation",
    "values",
    "open_threads",
    "relationships",
    "communication_style",
];

const SYSTEM_PROMPT: &str = "You maintain a short standing summary of one person, the part of \
their memory that is always in context. You are given the current summary and what the system \
has learned since. Rewrite only the sections the new material actually changes, and leave the \
rest byte for byte. Every sentence must be supportable by the material given; write nothing \
speculative. Answer with a JSON array only. Each item: {\"section\": one of identity, \
current_situation, values, open_threads, relationships, communication_style, \"content\": the \
rewritten section, at most 90 words}. Return only the sections you changed, and [] when nothing \
material changed.";

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CoreSection {
    pub section: String,
    pub content: String,
    pub tokens: i32,
    pub updated_at: DateTime<Utc>,
    pub updated_by: String,
}

#[derive(Debug, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CoreRewriteOutcome {
    pub sections_rewritten: usize,
    pub beliefs_read: usize,
    pub tokens: i32,
}

pub fn estimate_tokens(text: &str) -> i32 {
    i32::try_from(text.chars().count() / 4).unwrap_or(i32::MAX)
}

pub async fn load(pool: &PgPool) -> Result<Vec<CoreSection>, sqlx::Error> {
    type Row = (String, String, i32, DateTime<Utc>, String);
    let rows = sqlx::query_as::<_, Row>(
        "SELECT section, content, tokens, updated_at, updated_by FROM core_memory ORDER BY section",
    )
    .fetch_all(pool)
    .await?;
    let mut sections = rows
        .into_iter()
        .map(
            |(section, content, tokens, updated_at, updated_by)| CoreSection {
                section,
                content,
                tokens,
                updated_at,
                updated_by,
            },
        )
        .collect::<Vec<_>>();
    sections.sort_by_key(|section| {
        SECTIONS
            .iter()
            .position(|name| *name == section.section)
            .unwrap_or(usize::MAX)
    });
    Ok(sections)
}

pub async fn put(
    pool: &PgPool,
    section: &str,
    content: &str,
    updated_by: &str,
) -> Result<(), sqlx::Error> {
    sqlx::query(
        "INSERT INTO core_memory (section, content, tokens, updated_by) VALUES ($1, $2, $3, $4) ON CONFLICT (section) DO UPDATE SET content = EXCLUDED.content, tokens = EXCLUDED.tokens, updated_at = now(), updated_by = EXCLUDED.updated_by",
    )
    .bind(section)
    .bind(content)
    .bind(estimate_tokens(content))
    .bind(updated_by)
    .execute(pool)
    .await?;
    Ok(())
}

pub async fn block(pool: &PgPool) -> String {
    let sections = load(pool).await.unwrap_or_default();
    if sections.is_empty() {
        return String::new();
    }
    sections
        .iter()
        .filter(|section| !section.content.trim().is_empty())
        .map(|section| format!("{}: {}", section.section.replace('_', " "), section.content))
        .collect::<Vec<_>>()
        .join("\n")
}

pub async fn rewrite(
    pool: &PgPool,
    reason: &ReasonClient,
) -> Result<CoreRewriteOutcome, Box<dyn Error + Send + Sync>> {
    if !reason.configured() {
        return Err(Box::new(ReasonError::unconfigured()));
    }

    type BeliefRow = (Uuid, String, f32, String, String);
    let beliefs = sqlx::query_as::<_, BeliefRow>(
        "SELECT id, statement, confidence, corroboration, kind FROM beliefs WHERE status = 'active' ORDER BY confidence * (1 + stability) DESC LIMIT 40",
    )
    .fetch_all(pool)
    .await?;
    let recent = sqlx::query_as::<_, (DateTime<Utc>, String)>(
        "SELECT occurred_at, title FROM episodes ORDER BY occurred_at DESC LIMIT 15",
    )
    .fetch_all(pool)
    .await?;

    let mut outcome = CoreRewriteOutcome {
        sections_rewritten: 0,
        beliefs_read: beliefs.len(),
        tokens: 0,
    };
    if beliefs.is_empty() {
        return Ok(outcome);
    }

    let current = load(pool).await?;
    let current_block = if current.is_empty() {
        "The summary is empty; write it from scratch.".to_owned()
    } else {
        current
            .iter()
            .map(|section| format!("[{}]\n{}", section.section, section.content))
            .collect::<Vec<_>>()
            .join("\n\n")
    };
    let belief_block = beliefs
        .iter()
        .map(|(_, statement, confidence, corroboration, kind)| {
            format!("- ({kind}, {corroboration}, confidence {confidence:.2}) {statement}")
        })
        .collect::<Vec<_>>()
        .join("\n");
    let recent_block = recent
        .iter()
        .map(|(occurred_at, title)| format!("- {} {title}", occurred_at.format("%Y-%m-%d")))
        .collect::<Vec<_>>()
        .join("\n");

    let prompt = format!(
        "Current summary:\n{current_block}\n\nWhat the system now believes:\n{belief_block}\n\nRecent episodes:\n{recent_block}"
    );
    let candidates = reason.complete_array(SYSTEM_PROMPT, &prompt).await?;

    for candidate in candidates.as_array().into_iter().flatten() {
        let Some(section) = candidate
            .get("section")
            .and_then(Value::as_str)
            .filter(|section| SECTIONS.contains(section))
        else {
            continue;
        };
        let Some(content) = candidate
            .get("content")
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|content| !content.is_empty())
        else {
            continue;
        };
        let trimmed = trim_words(content, 110);
        put(pool, section, &trimmed, "nightly").await?;
        outcome.sections_rewritten += 1;
    }

    outcome.tokens = load(pool)
        .await?
        .iter()
        .map(|section| section.tokens)
        .sum::<i32>();
    Ok(outcome)
}

pub fn trim_words(text: &str, limit: usize) -> String {
    let words = text.split_whitespace().collect::<Vec<_>>();
    if words.len() <= limit {
        return text.trim().to_owned();
    }
    words[..limit].join(" ")
}

#[cfg(test)]
mod tests {
    use super::{estimate_tokens, trim_words};

    #[test]
    fn tokens_scale_with_length() {
        assert_eq!(estimate_tokens("abcd"), 1);
        assert_eq!(estimate_tokens(""), 0);
    }

    #[test]
    fn trimming_keeps_short_text_whole() {
        assert_eq!(trim_words("one two three", 10), "one two three");
        assert_eq!(trim_words("one two three", 2), "one two");
    }
}
