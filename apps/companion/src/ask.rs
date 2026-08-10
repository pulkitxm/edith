use std::error::Error;

use serde::Serialize;
use serde_json::Value;
use uuid::Uuid;

use crate::friend::{FriendDeps, answer_with_persona};
use crate::grounding::GroundingReport;
use crate::persona;
use crate::retrieve::{BeliefHit, ObservationHit};

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AskCitation {
    pub episode_id: Uuid,
    pub quote: String,
    pub support: String,
    pub title: String,
    pub occurred_at: String,
}

fn squeeze(text: &str) -> String {
    text.split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
        .to_lowercase()
}

pub fn resolve_support(claimed: Option<&str>, quote: &str, source: &str) -> String {
    let quote_appears = !quote.is_empty() && squeeze(source).contains(&squeeze(quote));
    match claimed {
        Some("verbatim") if quote_appears => "verbatim".to_owned(),
        Some("verbatim") => "paraphrase".to_owned(),
        Some("paraphrase") if quote_appears => "verbatim".to_owned(),
        Some("paraphrase") => "paraphrase".to_owned(),
        Some("inference") => "inference".to_owned(),
        _ if quote_appears => "verbatim".to_owned(),
        _ => "inference".to_owned(),
    }
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AskOutcome {
    pub answer: String,
    pub citations: Vec<AskCitation>,
    pub chunks_considered: usize,
    pub model: String,
    pub persona: String,
    pub abstained: bool,
    pub grounding: GroundingReport,
    pub reframed: Option<String>,
    pub opinion: Option<String>,
    pub beliefs: Vec<BeliefHit>,
    pub observations: Vec<ObservationHit>,
    pub stages: Vec<String>,
}

pub fn extract_json_object(text: &str) -> Option<Value> {
    let start = text.find('{')?;
    let end = text.rfind('}')?;
    if end <= start {
        return None;
    }
    serde_json::from_str::<Value>(&text[start..=end])
        .ok()
        .filter(Value::is_object)
}

pub async fn ask_run(
    deps: &FriendDeps<'_>,
    question: &str,
    persona_id: Option<&str>,
) -> Result<AskOutcome, Box<dyn Error + Send + Sync>> {
    let lens = match persona_id {
        Some(id) => persona::find(id).ok_or_else(|| format!("no persona named {id}"))?,
        None => persona::find("analyst").unwrap_or_else(persona::default_persona),
    };
    let answered = answer_with_persona(deps, &lens, question).await?;
    Ok(AskOutcome {
        answer: answered.answer,
        citations: answered.citations,
        chunks_considered: answered.chunks_considered,
        model: answered.model,
        persona: answered.persona,
        abstained: answered.abstained,
        grounding: answered.grounding,
        reframed: answered.reframed,
        opinion: answered.opinion,
        beliefs: answered.beliefs,
        observations: answered.observations,
        stages: answered.stages,
    })
}

#[cfg(test)]
mod tests {
    use super::{extract_json_object, resolve_support};

    #[test]
    fn finds_object_inside_prose() {
        let text = "Sure:\n{\"answer\": \"yes\", \"citations\": []}\nthat is all";
        let value = extract_json_object(text).unwrap();
        assert_eq!(value["answer"], "yes");
    }

    #[test]
    fn rejects_missing_object() {
        assert!(extract_json_object("nothing structured").is_none());
    }

    #[test]
    fn verbatim_requires_the_quote_to_appear() {
        let source = "Shipped the auth refactor this week.\nFelt slower than usual.";
        assert_eq!(
            resolve_support(Some("verbatim"), "shipped the auth refactor", source),
            "verbatim"
        );
        assert_eq!(
            resolve_support(Some("verbatim"), "the refactor shipped smoothly", source),
            "paraphrase"
        );
    }

    #[test]
    fn appearing_quotes_upgrade_and_missing_claims_default() {
        let source = "Felt slower than usual.";
        assert_eq!(
            resolve_support(Some("paraphrase"), "felt slower than usual", source),
            "verbatim"
        );
        assert_eq!(resolve_support(None, "", source), "inference");
        assert_eq!(
            resolve_support(Some("inference"), "felt slower", source),
            "inference"
        );
    }
}
