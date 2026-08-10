use std::env;
use std::error::Error;
use std::fmt::{Display, Formatter};

use futures_util::StreamExt;
use reqwest::Client;
use serde_json::{Value, json};

#[derive(Debug)]
pub struct ReasonError(String);

impl Display for ReasonError {
    fn fmt(&self, formatter: &mut Formatter<'_>) -> std::fmt::Result {
        formatter.write_str(&self.0)
    }
}

impl Error for ReasonError {}

impl ReasonError {
    pub fn unconfigured() -> Self {
        Self(
            "no reasoning provider: set ANTHROPIC_API_KEY, or REASON_PROVIDER=openai with REASON_URL"
                .to_owned(),
        )
    }
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct ReasonConfig {
    pub provider: String,
    pub url: String,
    pub model: String,
    pub api_key: String,
}

impl ReasonConfig {
    pub fn from_env() -> Self {
        Self {
            provider: env::var("REASON_PROVIDER").unwrap_or_default(),
            url: env::var("REASON_URL").unwrap_or_default(),
            model: env::var("REASON_MODEL").unwrap_or_default(),
            api_key: env::var("ANTHROPIC_API_KEY").unwrap_or_default(),
        }
    }
}

#[derive(Clone)]
enum Provider {
    Anthropic { key: String },
    OpenAiCompatible { base_url: String, key: String },
    Unconfigured,
}

#[derive(Clone)]
pub struct ReasonClient {
    client: Client,
    provider: Provider,
    model: String,
    config: ReasonConfig,
}

impl ReasonClient {
    pub fn from_config(config: ReasonConfig) -> Self {
        let provider = match config.provider.as_str() {
            "openai" if !config.url.is_empty() => Provider::OpenAiCompatible {
                base_url: config.url.trim_end_matches('/').to_owned(),
                key: config.api_key.clone(),
            },
            "openai" => Provider::Unconfigured,
            _ if !config.api_key.is_empty() => Provider::Anthropic {
                key: config.api_key.clone(),
            },
            _ => Provider::Unconfigured,
        };
        let model = if config.model.is_empty() {
            match provider {
                Provider::Anthropic { .. } => "claude-sonnet-5".to_owned(),
                _ => "qwen3:1.7b".to_owned(),
            }
        } else {
            config.model.clone()
        };
        Self {
            client: Client::new(),
            provider,
            model,
            config,
        }
    }

    pub fn config(&self) -> &ReasonConfig {
        &self.config
    }

    pub fn configured(&self) -> bool {
        !matches!(self.provider, Provider::Unconfigured)
    }

    pub fn provider_name(&self) -> &'static str {
        match self.provider {
            Provider::Anthropic { .. } => "anthropic",
            Provider::OpenAiCompatible { .. } => "openai",
            Provider::Unconfigured => "unconfigured",
        }
    }

    pub fn model_name(&self) -> &str {
        &self.model
    }

    pub fn describe(&self) -> String {
        match &self.provider {
            Provider::Anthropic { .. } => format!("anthropic, model {}", self.model),
            Provider::OpenAiCompatible { base_url, .. } => {
                format!("openai-compatible at {base_url}, model {}", self.model)
            }
            Provider::Unconfigured => "not configured".to_owned(),
        }
    }

    pub async fn complete(&self, system: &str, user: &str) -> Result<String, ReasonError> {
        let messages = vec![("user".to_owned(), user.to_owned())];
        match &self.provider {
            Provider::Anthropic { key } => {
                let body = self.anthropic_body(system, &messages, false);
                let response = self.anthropic_send(key, &body).await?;
                let (status, text) = read_response(response).await?;
                if !status.is_success() {
                    return Err(ReasonError(format!("Reasoning returned {status}: {text}")));
                }
                let value = parse_json(&text)?;
                value
                    .pointer("/content/0/text")
                    .and_then(Value::as_str)
                    .map(str::to_owned)
                    .ok_or_else(|| ReasonError("Reasoning response had no text".to_owned()))
            }
            Provider::OpenAiCompatible { base_url, key } => {
                let body = openai_body(&self.model, system, &messages, false);
                let response = self.openai_send(base_url, key, &body).await?;
                let (status, text) = read_response(response).await?;
                if !status.is_success() {
                    return Err(ReasonError(format!("Reasoning returned {status}: {text}")));
                }
                let value = parse_json(&text)?;
                value
                    .pointer("/choices/0/message/content")
                    .and_then(Value::as_str)
                    .map(str::to_owned)
                    .ok_or_else(|| ReasonError("Reasoning response had no text".to_owned()))
            }
            Provider::Unconfigured => Err(ReasonError::unconfigured()),
        }
    }

    pub async fn stream_chat(
        &self,
        system: &str,
        messages: &[(String, String)],
        on_delta: &mut (dyn FnMut(&str) + Send),
    ) -> Result<String, ReasonError> {
        match &self.provider {
            Provider::Anthropic { key } => {
                let body = self.anthropic_body(system, messages, true);
                let response = self.anthropic_send(key, &body).await?;
                stream_deltas(response, anthropic_delta, on_delta).await
            }
            Provider::OpenAiCompatible { base_url, key } => {
                let body = openai_body(&self.model, system, messages, true);
                let response = self.openai_send(base_url, key, &body).await?;
                stream_deltas(response, openai_delta, on_delta).await
            }
            Provider::Unconfigured => Err(ReasonError::unconfigured()),
        }
    }

    fn anthropic_body(&self, system: &str, messages: &[(String, String)], stream: bool) -> Value {
        json!({
            "model": self.model,
            "max_tokens": 2048,
            "system": system,
            "messages": role_messages(messages),
            "stream": stream,
        })
    }

    async fn anthropic_send(
        &self,
        key: &str,
        body: &Value,
    ) -> Result<reqwest::Response, ReasonError> {
        self.client
            .post("https://api.anthropic.com/v1/messages")
            .header("x-api-key", key)
            .header("anthropic-version", "2023-06-01")
            .json(body)
            .send()
            .await
            .map_err(|error| ReasonError(format!("Reasoning request failed: {error}")))
    }

    async fn openai_send(
        &self,
        base_url: &str,
        key: &str,
        body: &Value,
    ) -> Result<reqwest::Response, ReasonError> {
        let mut request = self.client.post(format!("{base_url}/chat/completions"));
        if !key.is_empty() {
            request = request.header("authorization", format!("Bearer {key}"));
        }
        request
            .json(body)
            .send()
            .await
            .map_err(|error| ReasonError(format!("Reasoning request failed: {error}")))
    }
}

fn role_messages(messages: &[(String, String)]) -> Vec<Value> {
    messages
        .iter()
        .map(|(role, content)| json!({"role": role, "content": content}))
        .collect()
}

fn openai_body(model: &str, system: &str, messages: &[(String, String)], stream: bool) -> Value {
    let mut all = vec![json!({"role": "system", "content": system})];
    all.extend(role_messages(messages));
    json!({"model": model, "messages": all, "stream": stream})
}

async fn read_response(
    response: reqwest::Response,
) -> Result<(reqwest::StatusCode, String), ReasonError> {
    let status = response.status();
    let text = response
        .text()
        .await
        .map_err(|error| ReasonError(format!("Reasoning response unreadable: {error}")))?;
    Ok((status, text))
}

fn parse_json(text: &str) -> Result<Value, ReasonError> {
    serde_json::from_str::<Value>(text)
        .map_err(|error| ReasonError(format!("Invalid reasoning response: {error}")))
}

pub fn anthropic_delta(value: &Value) -> Option<String> {
    if value.get("type").and_then(Value::as_str) != Some("content_block_delta") {
        return None;
    }
    value
        .pointer("/delta/text")
        .and_then(Value::as_str)
        .map(str::to_owned)
}

pub fn openai_delta(value: &Value) -> Option<String> {
    value
        .pointer("/choices/0/delta/content")
        .and_then(Value::as_str)
        .map(str::to_owned)
}

pub fn sse_data_payload(line: &str) -> Option<&str> {
    let trimmed = line.trim_end_matches('\r');
    let payload = trimmed.strip_prefix("data:")?.trim_start();
    if payload.is_empty() || payload == "[DONE]" {
        return None;
    }
    Some(payload)
}

async fn stream_deltas(
    response: reqwest::Response,
    extract: fn(&Value) -> Option<String>,
    on_delta: &mut (dyn FnMut(&str) + Send),
) -> Result<String, ReasonError> {
    let status = response.status();
    if !status.is_success() {
        let text = response.text().await.unwrap_or_default();
        return Err(ReasonError(format!("Reasoning returned {status}: {text}")));
    }

    let mut stream = response.bytes_stream();
    let mut buffer = String::new();
    let mut full = String::new();
    while let Some(chunk) = stream.next().await {
        let chunk =
            chunk.map_err(|error| ReasonError(format!("Reasoning stream failed: {error}")))?;
        buffer.push_str(&String::from_utf8_lossy(&chunk));
        while let Some(newline) = buffer.find('\n') {
            let line = buffer[..newline].to_owned();
            buffer.drain(..=newline);
            let Some(payload) = sse_data_payload(&line) else {
                continue;
            };
            let Ok(value) = serde_json::from_str::<Value>(payload) else {
                continue;
            };
            if let Some(error) = value.get("error") {
                return Err(ReasonError(format!("Reasoning stream error: {error}")));
            }
            if let Some(delta) = extract(&value) {
                full.push_str(&delta);
                on_delta(&delta);
            }
        }
    }

    if full.is_empty() {
        return Err(ReasonError("Reasoning stream had no text".to_owned()));
    }
    Ok(full)
}

pub fn extract_json_array(text: &str) -> Option<Value> {
    if let Some(start) = text.find('[')
        && let Some(end) = text.rfind(']')
        && end > start
        && let Ok(value) = serde_json::from_str::<Value>(&text[start..=end])
        && value.is_array()
    {
        return Some(value);
    }
    let start = text.find('{')?;
    let end = text.rfind('}')?;
    if end <= start {
        return None;
    }
    let object = serde_json::from_str::<Value>(&text[start..=end]).ok()?;
    object
        .as_object()?
        .values()
        .find(|value| value.is_array())
        .cloned()
}

pub const JSON_ONLY_RETRY: &str = "That answer was not JSON. Answer again with the JSON array \
alone: no prose, no headings, no markdown fences, starting with [ and ending with ].";

impl ReasonClient {
    pub async fn complete_array(&self, system: &str, user: &str) -> Result<Value, ReasonError> {
        let first = self.complete(system, user).await?;
        if let Some(array) = extract_json_array(&first) {
            return Ok(array);
        }
        let retry = format!("{user}\n\n{JSON_ONLY_RETRY}");
        let second = self.complete(system, &retry).await?;
        extract_json_array(&second).ok_or_else(|| {
            ReasonError(format!(
                "the answer was not a JSON array after a retry: {}",
                second.chars().take(200).collect::<String>()
            ))
        })
    }
}

#[cfg(test)]
mod tests {
    use super::{
        ReasonClient, ReasonConfig, anthropic_delta, extract_json_array, openai_delta,
        sse_data_payload,
    };
    use serde_json::json;

    #[test]
    fn finds_an_array_wrapped_in_an_object() {
        let text = "Here you go: {\"theories\": [{\"statement\": \"one\"}]}";
        let value = extract_json_array(text).unwrap();
        assert_eq!(value[0]["statement"], "one");
    }

    #[test]
    fn finds_array_inside_prose() {
        let text = "Here you go:\n[{\"statement\": \"x\"}]\nDone.";
        let value = extract_json_array(text).unwrap();
        assert_eq!(value[0]["statement"], "x");
    }

    #[test]
    fn rejects_missing_array() {
        assert!(extract_json_array("no json here").is_none());
        assert!(extract_json_array("] backwards [").is_none());
    }

    #[test]
    fn data_payloads_skip_blanks_and_done() {
        assert_eq!(sse_data_payload("data: {\"a\":1}"), Some("{\"a\":1}"));
        assert_eq!(sse_data_payload("data: [DONE]"), None);
        assert_eq!(sse_data_payload("event: ping"), None);
        assert_eq!(sse_data_payload("data: {\"a\":1}\r"), Some("{\"a\":1}"));
    }

    #[test]
    fn provider_deltas_extract_text() {
        let anthropic =
            json!({"type": "content_block_delta", "delta": {"type": "text_delta", "text": "hi"}});
        assert_eq!(anthropic_delta(&anthropic).as_deref(), Some("hi"));
        assert_eq!(anthropic_delta(&json!({"type": "message_start"})), None);
        let openai = json!({"choices": [{"delta": {"content": "yo"}}]});
        assert_eq!(openai_delta(&openai).as_deref(), Some("yo"));
        assert_eq!(openai_delta(&json!({"choices": [{"delta": {}}]})), None);
    }

    #[test]
    fn config_resolves_providers() {
        let anthropic = ReasonClient::from_config(ReasonConfig {
            provider: String::new(),
            url: String::new(),
            model: String::new(),
            api_key: "sk-test".to_owned(),
        });
        assert!(anthropic.configured());
        assert_eq!(anthropic.provider_name(), "anthropic");
        assert_eq!(anthropic.model_name(), "claude-sonnet-5");

        let openai = ReasonClient::from_config(ReasonConfig {
            provider: "openai".to_owned(),
            url: "http://ollama:11434/v1/".to_owned(),
            model: "qwen3:1.7b".to_owned(),
            api_key: String::new(),
        });
        assert!(openai.configured());
        assert_eq!(openai.provider_name(), "openai");

        let unconfigured = ReasonClient::from_config(ReasonConfig::default());
        assert!(!unconfigured.configured());
        assert_eq!(unconfigured.provider_name(), "unconfigured");
    }
}
