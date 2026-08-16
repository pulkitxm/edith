use std::error::Error;

use chrono::{DateTime, Utc};
use reqwest::Client;
use serde::Serialize;
use serde_json::{Value, json};
use sqlx::PgPool;

use crate::ingest::{IngestFile, ingest_files};

pub const API_VERSION: &str = "2026-03-11";
pub const RATE_LIMIT_PER_SECOND: f64 = 2.5;

#[derive(Clone)]
pub struct NotionConnector {
    client: Client,
    token: String,
}

#[derive(Debug, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct NotionOutcome {
    pub pages_seen: usize,
    pub pages_written: usize,
    pub episodes_ingested: usize,
    pub watermark: Option<String>,
    pub full_scan: bool,
}

pub fn plain_text(rich: &Value) -> String {
    rich.as_array()
        .map(|items| {
            items
                .iter()
                .filter_map(|item| item.get("plain_text").and_then(Value::as_str))
                .collect::<Vec<_>>()
                .join("")
        })
        .unwrap_or_default()
}

pub fn page_title(page: &Value) -> String {
    let properties = page.get("properties").and_then(Value::as_object);
    let from_properties = properties.and_then(|properties| {
        properties.values().find_map(|property| {
            if property.get("type").and_then(Value::as_str) == Some("title") {
                let text = plain_text(property.get("title")?);
                return (!text.trim().is_empty()).then_some(text);
            }
            None
        })
    });
    from_properties.unwrap_or_else(|| "Untitled".to_owned())
}

pub fn block_markdown(block: &Value) -> Option<String> {
    let kind = block.get("type").and_then(Value::as_str)?;
    let content = block.get(kind)?;
    let text = content.get("rich_text").map(plain_text).unwrap_or_default();
    let rendered = match kind {
        "heading_1" => format!("# {text}"),
        "heading_2" => format!("## {text}"),
        "heading_3" => format!("### {text}"),
        "bulleted_list_item" => format!("- {text}"),
        "numbered_list_item" => format!("1. {text}"),
        "to_do" => {
            let done = content
                .get("checked")
                .and_then(Value::as_bool)
                .unwrap_or(false);
            format!("- [{}] {text}", if done { "x" } else { " " })
        }
        "quote" => format!("> {text}"),
        "code" => {
            let language = content
                .get("language")
                .and_then(Value::as_str)
                .unwrap_or_default();
            format!("```{language}\n{text}\n```")
        }
        "divider" => "---".to_owned(),
        "paragraph" | "callout" | "toggle" => text,
        _ => text,
    };
    let trimmed = rendered.trim().to_owned();
    (!trimmed.is_empty()).then_some(trimmed)
}

pub fn search_body(watermark: Option<&str>) -> Value {
    let mut body = json!({
        "filter": {"value": "page", "property": "object"},
        "sort": {"direction": "descending", "timestamp": "last_edited_time"},
        "page_size": 50,
    });
    if let Some(watermark) = watermark {
        body["start_cursor_note"] = json!(watermark);
    }
    body
}

pub fn front_matter(page_id: &str, title: &str, edited: &str, url: &str) -> String {
    format!("---\ntitle: {title}\ndate: {edited}\nnotion_page: {page_id}\nsource: {url}\n---\n\n")
}

impl NotionConnector {
    pub fn with_token(token: &str) -> Self {
        Self {
            client: Client::new(),
            token: token.trim().to_owned(),
        }
    }

    pub fn configured(&self) -> bool {
        !self.token.is_empty()
    }

    pub fn describe(&self) -> String {
        match crate::settings::hint(&self.token) {
            Some(hint) => format!("{hint}, API {API_VERSION}"),
            None => "no token; set it from the app or `ed companion connectors set`".to_owned(),
        }
    }

    async fn post(&self, path: &str, body: &Value) -> Result<Value, Box<dyn Error + Send + Sync>> {
        let response = self
            .client
            .post(format!("https://api.notion.com/v1/{path}"))
            .bearer_auth(&self.token)
            .header("Notion-Version", API_VERSION)
            .json(body)
            .send()
            .await?;
        let status = response.status();
        let text = response.text().await?;
        if !status.is_success() {
            return Err(format!("notion {path} returned {status}: {text}").into());
        }
        Ok(serde_json::from_str(&text)?)
    }

    async fn get(&self, path: &str) -> Result<Value, Box<dyn Error + Send + Sync>> {
        let response = self
            .client
            .get(format!("https://api.notion.com/v1/{path}"))
            .bearer_auth(&self.token)
            .header("Notion-Version", API_VERSION)
            .send()
            .await?;
        let status = response.status();
        let text = response.text().await?;
        if !status.is_success() {
            return Err(format!("notion {path} returned {status}: {text}").into());
        }
        Ok(serde_json::from_str(&text)?)
    }

    async fn page_markdown(&self, page_id: &str) -> Result<String, Box<dyn Error + Send + Sync>> {
        let mut lines = Vec::new();
        let mut cursor: Option<String> = None;
        loop {
            let path = match &cursor {
                Some(cursor) => {
                    format!("blocks/{page_id}/children?page_size=100&start_cursor={cursor}")
                }
                None => format!("blocks/{page_id}/children?page_size=100"),
            };
            let value = self.get(&path).await?;
            for block in value
                .get("results")
                .and_then(Value::as_array)
                .into_iter()
                .flatten()
            {
                if let Some(rendered) = block_markdown(block) {
                    lines.push(rendered);
                }
            }
            match value.get("next_cursor").and_then(Value::as_str) {
                Some(next) => cursor = Some(next.to_owned()),
                None => break,
            }
            self.pace().await;
        }
        Ok(lines.join("\n\n"))
    }

    async fn pace(&self) {
        let millis = (1000.0 / RATE_LIMIT_PER_SECOND) as u64;
        tokio::time::sleep(std::time::Duration::from_millis(millis)).await;
    }

    pub async fn sync(
        &self,
        pool: &PgPool,
        vault_dir: &std::path::Path,
        full: bool,
    ) -> Result<NotionOutcome, Box<dyn Error + Send + Sync>> {
        if !self.configured() {
            return Err("no NOTION_TOKEN is set".into());
        }
        let watermark = crate::settings::load_all(pool)
            .await
            .unwrap_or_default()
            .get("notion.watermark")
            .cloned();
        let since = if full {
            None
        } else {
            watermark
                .as_deref()
                .and_then(|value| DateTime::parse_from_rfc3339(value).ok())
                .map(|value| value.with_timezone(&Utc))
        };

        let mut outcome = NotionOutcome {
            full_scan: full,
            ..NotionOutcome::default()
        };
        let mut observed: Option<DateTime<Utc>> = None;
        let mut files = Vec::new();
        let mut cursor: Option<String> = None;

        loop {
            let mut body = search_body(None);
            if let Some(cursor) = &cursor {
                body["start_cursor"] = json!(cursor);
            }
            let value = self.post("search", &body).await?;
            let results = value
                .get("results")
                .and_then(Value::as_array)
                .cloned()
                .unwrap_or_default();
            if results.is_empty() {
                break;
            }
            let mut reached_watermark = false;
            for page in &results {
                outcome.pages_seen += 1;
                let Some(page_id) = page.get("id").and_then(Value::as_str) else {
                    continue;
                };
                let edited = page
                    .get("last_edited_time")
                    .and_then(Value::as_str)
                    .unwrap_or_default();
                let edited_at = DateTime::parse_from_rfc3339(edited)
                    .ok()
                    .map(|value| value.with_timezone(&Utc));
                if let Some(edited_at) = edited_at
                    && observed.is_none_or(|current| edited_at > current)
                {
                    observed = Some(edited_at);
                }
                if let (Some(edited_at), Some(since)) = (edited_at, since)
                    && edited_at <= since
                {
                    reached_watermark = true;
                    break;
                }

                let title = page_title(page);
                let url = page.get("url").and_then(Value::as_str).unwrap_or_default();
                let markdown = self.page_markdown(page_id).await?;
                if markdown.trim().is_empty() {
                    continue;
                }
                let text = format!("{}{markdown}", front_matter(page_id, &title, edited, url));
                let relative = format!("notion/{page_id}.md");
                let path = vault_dir.join(&relative);
                if let Some(parent) = path.parent() {
                    tokio::fs::create_dir_all(parent).await?;
                }
                tokio::fs::write(&path, text.as_bytes()).await?;
                outcome.pages_written += 1;
                files.push(IngestFile {
                    name: relative,
                    text,
                    mtime: Some(edited.to_owned()),
                });
                self.pace().await;
            }
            if reached_watermark {
                break;
            }
            match value.get("next_cursor").and_then(Value::as_str) {
                Some(next) => cursor = Some(next.to_owned()),
                None => break,
            }
            self.pace().await;
        }

        if !files.is_empty() {
            let ingested = ingest_files(pool, vault_dir, files).await?;
            outcome.episodes_ingested = ingested
                .iter()
                .filter(|entry| entry.status == "ingested")
                .count();
        }
        if let Some(observed) = observed {
            let stamp = observed.to_rfc3339();
            crate::settings::put(pool, "notion.watermark", &stamp).await?;
            outcome.watermark = Some(stamp);
        }
        Ok(outcome)
    }
}

#[cfg(test)]
mod tests {
    use super::{API_VERSION, block_markdown, front_matter, page_title, plain_text};
    use serde_json::json;

    #[test]
    fn the_api_version_is_the_data_sources_one() {
        assert_eq!(API_VERSION, "2026-03-11");
    }

    #[test]
    fn rich_text_flattens_to_plain_text() {
        let rich = json!([{"plain_text": "hello "}, {"plain_text": "world"}]);
        assert_eq!(plain_text(&rich), "hello world");
    }

    #[test]
    fn blocks_render_as_markdown() {
        let heading = json!({"type": "heading_2", "heading_2": {"rich_text": [{"plain_text": "Week"}]}});
        assert_eq!(block_markdown(&heading), Some("## Week".to_owned()));
        let todo = json!({"type": "to_do", "to_do": {"checked": true, "rich_text": [{"plain_text": "ship"}]}});
        assert_eq!(block_markdown(&todo), Some("- [x] ship".to_owned()));
        let empty = json!({"type": "paragraph", "paragraph": {"rich_text": []}});
        assert_eq!(block_markdown(&empty), None);
    }

    #[test]
    fn a_page_without_a_title_is_still_filed() {
        assert_eq!(page_title(&json!({"properties": {}})), "Untitled");
        let titled = json!({"properties": {"Name": {"type": "title", "title": [{"plain_text": "Standup"}]}}});
        assert_eq!(page_title(&titled), "Standup");
    }

    #[test]
    fn front_matter_carries_the_edit_date_back_to_ingestion() {
        let matter = front_matter("abc", "Standup", "2026-08-01T10:00:00Z", "https://notion.so/abc");
        assert!(matter.contains("date: 2026-08-01T10:00:00Z"));
        assert!(matter.contains("notion_page: abc"));
    }
}
