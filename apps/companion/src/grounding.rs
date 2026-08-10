use std::collections::HashSet;
use std::env;

use reqwest::Client;
use serde::Serialize;
use serde_json::{Value, json};

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct GroundingReport {
    pub score: f32,
    pub scorer: String,
    pub unsupported: Vec<String>,
}

#[derive(Clone)]
pub struct GroundingClient {
    client: Client,
    base_url: String,
    model: String,
}

impl GroundingClient {
    pub fn from_env() -> Self {
        Self {
            client: Client::new(),
            base_url: env::var("GROUNDING_URL")
                .unwrap_or_default()
                .trim_end_matches('/')
                .to_owned(),
            model: env::var("GROUNDING_MODEL")
                .unwrap_or_else(|_| "vectara/hallucination_evaluation_model".to_owned()),
        }
    }

    pub fn configured(&self) -> bool {
        !self.base_url.is_empty()
    }

    pub fn describe(&self) -> String {
        if self.configured() {
            format!("{} at {}", self.model, self.base_url)
        } else {
            "lexical overlap, no scorer configured".to_owned()
        }
    }

    pub async fn score(&self, evidence: &str, answer: &str) -> GroundingReport {
        if self.configured()
            && let Some(score) = self.remote_score(evidence, answer).await
        {
            return GroundingReport {
                score,
                scorer: self.model.clone(),
                unsupported: unsupported_sentences(evidence, answer),
            };
        }
        lexical_grounding(evidence, answer)
    }

    async fn remote_score(&self, evidence: &str, answer: &str) -> Option<f32> {
        let response = self
            .client
            .post(format!("{}/score", self.base_url))
            .json(&json!({
                "model": self.model,
                "premise": evidence,
                "hypothesis": answer,
            }))
            .send()
            .await
            .ok()?;
        if !response.status().is_success() {
            return None;
        }
        let value = response.json::<Value>().await.ok()?;
        value
            .get("score")
            .or_else(|| value.get("consistency"))
            .or_else(|| value.pointer("/0/score"))
            .and_then(Value::as_f64)
            .map(|score| score.clamp(0.0, 1.0) as f32)
    }
}

pub fn tokens(text: &str) -> HashSet<String> {
    text.split(|character: char| !character.is_alphanumeric())
        .filter(|word| word.len() > 3)
        .map(str::to_lowercase)
        .collect()
}

pub fn sentences(text: &str) -> Vec<String> {
    text.split(|character| matches!(character, '.' | '!' | '?' | '\n'))
        .map(str::trim)
        .filter(|sentence| sentence.split_whitespace().count() >= 4)
        .map(str::to_owned)
        .collect()
}

pub fn sentence_support(evidence_tokens: &HashSet<String>, sentence: &str) -> f32 {
    let claim = tokens(sentence);
    if claim.is_empty() {
        return 1.0;
    }
    let hits = claim
        .iter()
        .filter(|token| evidence_tokens.contains(*token))
        .count();
    hits as f32 / claim.len() as f32
}

pub fn unsupported_sentences(evidence: &str, answer: &str) -> Vec<String> {
    let evidence_tokens = tokens(evidence);
    sentences(answer)
        .into_iter()
        .filter(|sentence| sentence_support(&evidence_tokens, sentence) < 0.35)
        .collect()
}

pub fn lexical_grounding(evidence: &str, answer: &str) -> GroundingReport {
    let evidence_tokens = tokens(evidence);
    let claims = sentences(answer);
    if claims.is_empty() || evidence_tokens.is_empty() {
        return GroundingReport {
            score: 0.0,
            scorer: "lexical".to_owned(),
            unsupported: claims,
        };
    }
    let mut total = 0.0;
    let mut unsupported = Vec::new();
    for claim in &claims {
        let support = sentence_support(&evidence_tokens, claim);
        total += support;
        if support < 0.35 {
            unsupported.push(claim.clone());
        }
    }
    GroundingReport {
        score: (total / claims.len() as f32).clamp(0.0, 1.0),
        scorer: "lexical".to_owned(),
        unsupported,
    }
}

pub fn verbosity_flag(answer: &str, max_words: usize) -> bool {
    answer.split_whitespace().count() > max_words
}

#[cfg(test)]
mod tests {
    use super::{lexical_grounding, unsupported_sentences, verbosity_flag};

    #[test]
    fn an_answer_drawn_from_the_evidence_scores_high() {
        let evidence = "Shipped the auth refactor on Tuesday and felt slower than usual afterwards.";
        let answer = "You shipped the auth refactor on Tuesday and felt slower afterwards.";
        assert!(lexical_grounding(evidence, answer).score > 0.7);
    }

    #[test]
    fn invented_detail_is_named_as_unsupported() {
        let evidence = "Shipped the auth refactor on Tuesday.";
        let answer = "Your manager praised the billing migration during the quarterly review.";
        let report = lexical_grounding(evidence, answer);
        assert!(report.score < 0.35);
        assert_eq!(report.unsupported.len(), 1);
        assert_eq!(unsupported_sentences(evidence, answer).len(), 1);
    }

    #[test]
    fn long_answers_are_flagged() {
        let answer = "word ".repeat(300);
        assert!(verbosity_flag(&answer, 220));
        assert!(!verbosity_flag("short answer here", 220));
    }
}
