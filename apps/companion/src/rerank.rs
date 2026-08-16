use std::env;
use std::fmt::{Display, Formatter};

use reqwest::Client;
use serde_json::{Value, json};

#[derive(Debug)]
pub struct RerankError(String);

impl Display for RerankError {
    fn fmt(&self, formatter: &mut Formatter<'_>) -> std::fmt::Result {
        formatter.write_str(&self.0)
    }
}

impl std::error::Error for RerankError {}

#[derive(Clone)]
pub struct RerankClient {
    client: Client,
    base_url: String,
    model: String,
}

impl RerankClient {
    pub fn from_env() -> Self {
        Self {
            client: Client::new(),
            base_url: env::var("RERANK_URL")
                .unwrap_or_default()
                .trim_end_matches('/')
                .to_owned(),
            model: env::var("RERANK_MODEL").unwrap_or_else(|_| "qwen3-reranker:0.6b".to_owned()),
        }
    }

    pub fn configured(&self) -> bool {
        !self.base_url.is_empty()
    }

    pub fn describe(&self) -> String {
        if self.configured() {
            format!("{} at {}", self.model, self.base_url)
        } else {
            "not configured, fusion order kept".to_owned()
        }
    }

    pub async fn scores(
        &self,
        query: &str,
        documents: &[String],
    ) -> Result<Vec<f32>, RerankError> {
        if documents.is_empty() {
            return Ok(Vec::new());
        }
        if !self.configured() {
            return Err(RerankError("no reranker configured".to_owned()));
        }
        let response = self
            .client
            .post(format!("{}/rerank", self.base_url))
            .json(&json!({ "model": self.model, "query": query, "documents": documents }))
            .send()
            .await
            .map_err(|error| RerankError(format!("Rerank request failed: {error}")))?;
        let status = response.status();
        let text = response
            .text()
            .await
            .map_err(|error| RerankError(format!("Rerank body unreadable: {error}")))?;
        if !status.is_success() {
            return Err(RerankError(format!("Rerank returned {status}: {text}")));
        }
        let value = serde_json::from_str::<Value>(&text)
            .map_err(|error| RerankError(format!("Rerank response was not JSON: {error}")))?;
        parse_scores(&value, documents.len())
            .ok_or_else(|| RerankError(format!("Rerank response had no scores: {text}")))
    }
}

pub fn parse_scores(value: &Value, expected: usize) -> Option<Vec<f32>> {
    let results = value
        .get("results")
        .or_else(|| value.get("data"))
        .and_then(Value::as_array)?;
    let mut scores = vec![f32::MIN; expected];
    for entry in results {
        let index = entry
            .get("index")
            .and_then(Value::as_u64)
            .map(|index| index as usize)?;
        let score = entry
            .get("relevance_score")
            .or_else(|| entry.get("score"))
            .and_then(Value::as_f64)? as f32;
        if index < expected {
            scores[index] = score;
        }
    }
    if scores.contains(&f32::MIN) {
        return None;
    }
    Some(scores)
}

#[cfg(test)]
mod tests {
    use super::parse_scores;
    use serde_json::json;

    #[test]
    fn reads_relevance_scores_in_index_order() {
        let value = json!({"results": [
            {"index": 1, "relevance_score": 0.9},
            {"index": 0, "relevance_score": 0.2}
        ]});
        assert_eq!(parse_scores(&value, 2), Some(vec![0.2, 0.9]));
    }

    #[test]
    fn rejects_a_partial_answer() {
        let value = json!({"results": [{"index": 0, "score": 0.5}]});
        assert_eq!(parse_scores(&value, 2), None);
    }
}
