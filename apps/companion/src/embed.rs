use std::env;
use std::error::Error;
use std::fmt::{Display, Formatter};

use reqwest::Client;
use serde::Deserialize;
use serde_json::json;

#[derive(Debug)]
pub struct EmbedError(String);

impl Display for EmbedError {
    fn fmt(&self, formatter: &mut Formatter<'_>) -> std::fmt::Result {
        formatter.write_str(&self.0)
    }
}

impl Error for EmbedError {}

#[derive(Clone)]
pub struct EmbedClient {
    client: Client,
    base_url: String,
    model: String,
}

#[derive(Deserialize)]
struct EmbedResponse {
    embeddings: Vec<Vec<f32>>,
}

#[derive(Deserialize)]
struct VersionResponse {
    version: String,
}

impl EmbedClient {
    pub fn from_env() -> Self {
        let base_url = env::var("EMBED_URL")
            .unwrap_or_else(|_| "http://127.0.0.1:11434".to_owned())
            .trim_end_matches('/')
            .to_owned();
        let model = env::var("EMBED_MODEL").unwrap_or_else(|_| "qwen3-embedding:0.6b".to_owned());
        Self {
            client: Client::new(),
            base_url,
            model,
        }
    }

    pub fn model(&self) -> &str {
        &self.model
    }

    pub async fn embed(&self, texts: &[String]) -> Result<Vec<Vec<f32>>, EmbedError> {
        if texts.is_empty() {
            return Ok(Vec::new());
        }

        let response = self
            .client
            .post(format!("{}/api/embed", self.base_url))
            .json(&json!({ "model": self.model, "input": texts }))
            .send()
            .await
            .map_err(|error| EmbedError(format!("Embedding request failed: {error}")))?;
        let status = response.status();
        if !status.is_success() {
            let detail = response.text().await.unwrap_or_default();
            return Err(EmbedError(format!(
                "Embedding endpoint returned {status}: {detail}"
            )));
        }
        let response = response
            .json::<EmbedResponse>()
            .await
            .map_err(|error| EmbedError(format!("Invalid embedding response: {error}")))?;
        if response.embeddings.len() != texts.len() {
            return Err(EmbedError(format!(
                "Embedding endpoint returned {} vectors for {} inputs",
                response.embeddings.len(),
                texts.len()
            )));
        }

        response
            .embeddings
            .into_iter()
            .enumerate()
            .map(|(index, mut embedding)| {
                if embedding.len() < 512 {
                    return Err(EmbedError(format!(
                        "Embedding {index} has {} dimensions, expected at least 512",
                        embedding.len()
                    )));
                }
                embedding.truncate(512);
                let norm = embedding
                    .iter()
                    .map(|value| value * value)
                    .sum::<f32>()
                    .sqrt();
                if !norm.is_finite() || norm == 0.0 {
                    return Err(EmbedError(format!(
                        "Embedding {index} cannot be normalized"
                    )));
                }
                for value in &mut embedding {
                    *value /= norm;
                }
                Ok(embedding)
            })
            .collect()
    }

    pub async fn version_probe(&self) -> Result<String, EmbedError> {
        let response = self
            .client
            .get(format!("{}/api/version", self.base_url))
            .send()
            .await
            .map_err(|error| EmbedError(format!("Embedding version request failed: {error}")))?;
        let status = response.status();
        if !status.is_success() {
            let detail = response.text().await.unwrap_or_default();
            return Err(EmbedError(format!(
                "Embedding version endpoint returned {status}: {detail}"
            )));
        }
        response
            .json::<VersionResponse>()
            .await
            .map(|response| response.version)
            .map_err(|error| EmbedError(format!("Invalid embedding version response: {error}")))
    }
}
