use std::error::Error;

use chrono::{DateTime, Utc};
use serde_json::{Value, json};
use sqlx::PgPool;
use tokio::sync::mpsc::UnboundedSender;
use uuid::Uuid;

use crate::ask::{AskCitation, resolve_support};
use crate::core_memory;
use crate::embed::EmbedClient;
use crate::grounding::GroundingClient;
use crate::lenses;
use crate::persona::{self, Persona};
use crate::reason::{ReasonClient, extract_json_array};
use crate::rerank::RerankClient;
use crate::retrieve::{
    RetrievedItem, belief_channel, evidence_block, observation_channel, retrieve,
};
use crate::turns::{RetrievedChunk, TurnRecord, latency_since, log_turn_record};

pub const CITATIONS_MARKER: &str = "@@CITATIONS@@";
const THINK_OPEN: &str = "<think>";
const THINK_CLOSE: &str = "</think>";

const SYSTEM_PREFIX: &str = "You are the companion: a thoughtful confidant who knows one person \
through their own notes, voice memos and records. Excerpts from their memory that may relate to \
the conversation are provided below. Ground what you say in those excerpts and the conversation; \
when the memory does not answer, say so plainly instead of guessing. Reply naturally in plain \
prose. After your reply, on its own line, write @@CITATIONS@@ followed by a JSON array \
[{\"episodeId\": string, \"quote\": string, \"support\": \"verbatim\"|\"paraphrase\"|\
\"inference\"}] citing only episode ids you were given, or [] when nothing was cited.";

pub enum ChatEvent {
    Meta {
        conversation_id: Uuid,
        model: String,
    },
    Delta(String),
    Citations(Vec<AskCitation>),
    Done {
        message_id: Uuid,
        latency_ms: i32,
        chunks_considered: usize,
    },
    Failed(String),
}

#[derive(Default)]
pub struct StreamFilter {
    pending: String,
    thinking: bool,
    capturing: bool,
    citations: String,
}

impl StreamFilter {
    pub fn push(&mut self, delta: &str) -> String {
        if self.capturing {
            self.citations.push_str(delta);
            return String::new();
        }
        self.pending.push_str(delta);
        let mut visible = String::new();
        loop {
            if self.thinking {
                match self.pending.find(THINK_CLOSE) {
                    Some(end) => {
                        self.pending.drain(..end + THINK_CLOSE.len());
                        self.thinking = false;
                    }
                    None => return visible,
                }
                continue;
            }
            let think = self.pending.find(THINK_OPEN);
            let marker = self.pending.find(CITATIONS_MARKER);
            if let Some(t) = think.filter(|t| marker.is_none_or(|m| *t < m)) {
                visible.push_str(&self.pending[..t]);
                self.pending.drain(..t + THINK_OPEN.len());
                self.thinking = true;
            } else if let Some(m) = marker {
                visible.push_str(&self.pending[..m]);
                let rest = self.pending[m + CITATIONS_MARKER.len()..].to_owned();
                self.pending.clear();
                self.capturing = true;
                self.citations.push_str(&rest);
                return visible;
            } else {
                let hold = held_suffix(&self.pending);
                let cut = self.pending.len() - hold;
                visible.push_str(&self.pending[..cut]);
                self.pending.drain(..cut);
                return visible;
            }
        }
    }

    pub fn finish(mut self) -> (String, Option<Value>) {
        let leftover = if self.thinking {
            String::new()
        } else {
            std::mem::take(&mut self.pending)
        };
        let parsed = extract_json_array(&self.citations);
        (leftover, parsed)
    }
}

fn held_suffix(pending: &str) -> usize {
    let mut hold = 0;
    for token in [THINK_OPEN, CITATIONS_MARKER] {
        for length in (1..token.len()).rev() {
            if length <= pending.len()
                && pending.is_char_boundary(pending.len() - length)
                && pending.ends_with(&token[..length])
            {
                hold = hold.max(length);
                break;
            }
        }
    }
    hold
}

pub fn conversation_title(message: &str) -> String {
    let squeezed = message.split_whitespace().collect::<Vec<_>>().join(" ");
    if squeezed.chars().count() <= 60 {
        return squeezed;
    }
    let cut = squeezed.chars().take(60).collect::<String>();
    match cut.rfind(' ') {
        Some(space) if space > 20 => format!("{}…", &cut[..space]),
        _ => format!("{cut}…"),
    }
}

fn date_string(date: DateTime<Utc>) -> String {
    date.to_rfc3339_opts(chrono::SecondsFormat::AutoSi, true)
}

fn validate_citations(parsed: Option<&Value>, chunks: &[RetrievedItem]) -> Vec<AskCitation> {
    let mut citations = Vec::new();
    for citation in parsed.and_then(Value::as_array).into_iter().flatten() {
        let Some(episode_id) = citation
            .get("episodeId")
            .and_then(Value::as_str)
            .and_then(|value| Uuid::parse_str(value).ok())
        else {
            continue;
        };
        let Some(item) = chunks
            .iter()
            .find(|item| item.episode_id == Some(episode_id))
        else {
            continue;
        };
        let quote = citation
            .get("quote")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .trim()
            .to_owned();
        let support = resolve_support(
            citation.get("support").and_then(Value::as_str),
            &quote,
            &item.text,
        );
        citations.push(AskCitation {
            episode_id,
            quote,
            support,
            title: item.title.clone(),
            occurred_at: date_string(item.occurred_at),
        });
    }
    citations
}

pub async fn resolve_conversation(
    pool: &PgPool,
    conversation_id: Option<Uuid>,
    message: &str,
) -> Result<Uuid, Box<dyn Error + Send + Sync>> {
    match conversation_id {
        Some(id) => {
            let exists =
                sqlx::query_scalar::<_, bool>("SELECT true FROM conversations WHERE id = $1")
                    .bind(id)
                    .fetch_optional(pool)
                    .await?;
            if exists.is_none() {
                return Err("no such conversation".into());
            }
            Ok(id)
        }
        None => {
            let id = sqlx::query_scalar::<_, Uuid>(
                "INSERT INTO conversations (title) VALUES ($1) RETURNING id",
            )
            .bind(conversation_title(message))
            .fetch_one(pool)
            .await?;
            Ok(id)
        }
    }
}

pub struct ChatDeps<'a> {
    pub pool: &'a PgPool,
    pub embed: &'a EmbedClient,
    pub rerank: &'a RerankClient,
    pub grounding: &'a GroundingClient,
    pub reason: &'a ReasonClient,
    pub persona: Option<String>,
}

pub async fn chat_stream(
    deps: &ChatDeps<'_>,
    conversation_id: Uuid,
    message: &str,
    events: &UnboundedSender<ChatEvent>,
) {
    if let Err(error) = run(deps, conversation_id, message, events).await {
        let _ = events.send(ChatEvent::Failed(error.to_string()));
    }
}

fn chat_persona(id: Option<&str>) -> Persona {
    id.and_then(persona::find)
        .unwrap_or_else(persona::default_persona)
}

async fn run(
    deps: &ChatDeps<'_>,
    conversation_id: Uuid,
    message: &str,
    events: &UnboundedSender<ChatEvent>,
) -> Result<(), Box<dyn Error + Send + Sync>> {
    let pool = deps.pool;
    let embed = deps.embed;
    let reason = deps.reason;
    let lens = chat_persona(deps.persona.as_deref());
    let started = std::time::Instant::now();
    let model = reason.describe();
    let _ = events.send(ChatEvent::Meta {
        conversation_id,
        model: model.clone(),
    });

    let history = sqlx::query_as::<_, (String, String)>(
        "SELECT role, content FROM (SELECT role, content, created_at FROM messages WHERE conversation_id = $1 ORDER BY created_at DESC LIMIT 12) recent ORDER BY created_at ASC",
    )
    .bind(conversation_id)
    .fetch_all(pool)
    .await?;

    sqlx::query("INSERT INTO messages (conversation_id, role, content) VALUES ($1, 'user', $2)")
        .bind(conversation_id)
        .bind(message)
        .execute(pool)
        .await?;

    let policy = lens.policy();
    let retrieval = retrieve(pool, embed, deps.rerank, message, &policy).await?;
    let chunks = retrieval.items;
    let beliefs = belief_channel(pool, embed, message, &policy)
        .await
        .unwrap_or_default();
    let observations = observation_channel(pool, message, &policy, Utc::now())
        .await
        .unwrap_or_default();

    let material = evidence_block(&chunks, &beliefs, &observations);
    let material = if material.trim().is_empty() {
        "(the memory is empty so far)".to_owned()
    } else {
        material
    };
    let core = core_memory::block(pool).await;
    let mut system = SYSTEM_PREFIX.to_owned();
    if !core.is_empty() {
        system.push_str(&format!("\n\nWho they are right now:\n{core}"));
    }
    let lens_note = lenses::load(pool, &lens.id).await;
    system.push_str(&format!("\n\n{}", lens.voice_text));
    if !lens_note.trim().is_empty() {
        system.push_str(&format!(
            "\n\nWhat this lens has learned about being useful to them:\n{}",
            lens_note.trim()
        ));
    }
    system.push_str(&format!("\n\n{material}"));

    let mut messages = history;
    messages.push(("user".to_owned(), message.to_owned()));

    let mut filter = StreamFilter::default();
    let mut answer = String::new();
    let mut emit = |delta: &str| {
        let visible = filter.push(delta);
        if !visible.is_empty() {
            answer.push_str(&visible);
            let _ = events.send(ChatEvent::Delta(visible));
        }
    };
    reason.stream_chat(&system, &messages, &mut emit).await?;
    drop(emit);

    let (leftover, parsed) = filter.finish();
    if !leftover.is_empty() {
        answer.push_str(&leftover);
        let _ = events.send(ChatEvent::Delta(leftover));
    }
    let answer = answer.trim().to_owned();
    if answer.is_empty() {
        return Err("the reply was empty".into());
    }

    let citations = validate_citations(parsed.as_ref(), &chunks);
    let _ = events.send(ChatEvent::Citations(citations.clone()));

    let latency_ms = latency_since(started);
    let citations_json = serde_json::to_value(&citations).unwrap_or(Value::Null);
    let message_id = sqlx::query_scalar::<_, Uuid>(
        "INSERT INTO messages (conversation_id, role, content, citations, model, latency_ms) VALUES ($1, 'assistant', $2, $3, $4, $5) RETURNING id",
    )
    .bind(conversation_id)
    .bind(&answer)
    .bind(&citations_json)
    .bind(&model)
    .bind(latency_ms)
    .fetch_one(pool)
    .await?;
    sqlx::query("UPDATE conversations SET last_active_at = now() WHERE id = $1")
        .bind(conversation_id)
        .execute(pool)
        .await?;

    let grounding = deps.grounding.score(&material, &answer).await;
    let retrieved = chunks
        .iter()
        .enumerate()
        .map(|(rank, item)| {
            let cited = citations
                .iter()
                .any(|citation| Some(citation.episode_id) == item.episode_id);
            RetrievedChunk::from_item(item, rank as i32 + 1, cited)
        })
        .collect::<Vec<_>>();
    log_turn_record(
        pool,
        TurnRecord {
            kind: "chat",
            query: message,
            model: Some(&model),
            persona: Some(&lens.id),
            prompt_version: Some(crate::friend::PROMPT_VERSION),
            grounding_score: Some(grounding.score),
            abstained: false,
            latency_ms,
        },
        &retrieved,
    )
    .await;

    let _ = events.send(ChatEvent::Done {
        message_id,
        latency_ms,
        chunks_considered: chunks.len(),
    });
    Ok(())
}

pub fn event_json(event: &ChatEvent) -> (&'static str, Value) {
    match event {
        ChatEvent::Meta {
            conversation_id,
            model,
        } => (
            "meta",
            json!({"conversationId": conversation_id, "model": model}),
        ),
        ChatEvent::Delta(text) => ("delta", json!({"text": text})),
        ChatEvent::Citations(citations) => (
            "citations",
            serde_json::to_value(citations).unwrap_or_else(|_| json!([])),
        ),
        ChatEvent::Done {
            message_id,
            latency_ms,
            chunks_considered,
        } => (
            "done",
            json!({
                "messageId": message_id,
                "latencyMs": latency_ms,
                "chunksConsidered": chunks_considered,
            }),
        ),
        ChatEvent::Failed(message) => ("error", json!({"error": message})),
    }
}

#[cfg(test)]
mod tests {
    use super::{StreamFilter, conversation_title, held_suffix};

    fn run_chunks(chunks: &[&str]) -> (String, String, Option<serde_json::Value>) {
        let mut filter = StreamFilter::default();
        let mut visible = String::new();
        for chunk in chunks {
            visible.push_str(&filter.push(chunk));
        }
        let (leftover, citations) = filter.finish();
        (visible, leftover, citations)
    }

    #[test]
    fn passes_plain_text_through() {
        let (visible, leftover, citations) = run_chunks(&["Hello", " there."]);
        assert_eq!(format!("{visible}{leftover}"), "Hello there.");
        assert!(citations.is_none());
    }

    #[test]
    fn strips_thinking_even_across_chunks() {
        let (visible, leftover, _) = run_chunks(&["<thi", "nk>secret plans</th", "ink>the answer"]);
        assert_eq!(format!("{visible}{leftover}"), "the answer");
    }

    #[test]
    fn splits_citations_marker_across_chunks() {
        let (visible, leftover, citations) =
            run_chunks(&["It went well.\n@@CITA", "TIONS@@ [{\"episodeId\": \"x\"}]"]);
        assert_eq!(format!("{visible}{leftover}").trim_end(), "It went well.");
        assert!(citations.unwrap().is_array());
    }

    #[test]
    fn unclosed_think_drops_the_tail() {
        let (visible, leftover, _) = run_chunks(&["fine so far <think>never closed"]);
        assert_eq!(format!("{visible}{leftover}"), "fine so far ");
    }

    #[test]
    fn holds_only_plausible_prefixes() {
        assert_eq!(held_suffix("hello <t"), 2);
        assert_eq!(held_suffix("hello @@CITA"), 6);
        assert_eq!(held_suffix("hello."), 0);
    }

    #[test]
    fn titles_squeeze_and_truncate() {
        assert_eq!(conversation_title("  hi\nthere  "), "hi there");
        let long = "word ".repeat(30);
        let title = conversation_title(&long);
        assert!(title.chars().count() <= 61);
        assert!(title.ends_with('…'));
    }
}
