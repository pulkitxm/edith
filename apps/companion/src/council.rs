use std::error::Error;

use serde::Serialize;
use serde_json::Value;

use crate::ask::extract_json_object;
use crate::friend::{FriendDeps, PersonaAnswer, answer_with_persona};
use crate::persona::{self, Persona};
use crate::reason::ReasonError;

const SYNTHESIS_PROMPT: &str = "Several lenses answered the same question about one person, each \
from its own reading of the record. Your job is not to pick a winner or to average them. Find \
where they agree, name where they diverge and why, then locate the crux: the one specific fact \
none of them has, which would settle the disagreement if it were known. Answer with JSON only: \
{\"agreement\": string, \"divergence\": string, \"crux\": string, \"crux_question\": one \
question that would resolve it}. If they do not really disagree, say so in divergence and make \
the crux the weakest link in their shared reasoning.";

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CouncilOutcome {
    pub question: String,
    pub answers: Vec<PersonaAnswer>,
    pub agreement: String,
    pub divergence: String,
    pub crux: String,
    pub crux_question: String,
    pub model: String,
}

pub fn resolve_personas(requested: &[String]) -> Result<Vec<Persona>, String> {
    let wanted = if requested.is_empty() {
        vec![
            "analyst".to_owned(),
            "coach".to_owned(),
            "skeptic".to_owned(),
        ]
    } else {
        requested.to_vec()
    };
    let mut personas = Vec::new();
    for id in &wanted {
        match persona::find(id) {
            Some(found) => personas.push(found),
            None => return Err(format!("no persona named {id}")),
        }
    }
    if personas.len() < 2 {
        return Err("a council needs at least two personas".to_owned());
    }
    Ok(personas)
}

pub async fn council_run(
    deps: &FriendDeps<'_>,
    question: &str,
    requested: &[String],
) -> Result<CouncilOutcome, Box<dyn Error + Send + Sync>> {
    if !deps.reason.configured() {
        return Err(Box::new(ReasonError::unconfigured()));
    }
    let personas = resolve_personas(requested)?;
    let mut answers = Vec::new();
    for persona in &personas {
        answers.push(answer_with_persona(deps, persona, question).await?);
    }

    let transcript = answers
        .iter()
        .map(|answer| {
            format!(
                "{} (abstained: {}, grounding {:.2})\n{}",
                answer.label, answer.abstained, answer.grounding.score, answer.answer
            )
        })
        .collect::<Vec<_>>()
        .join("\n\n");
    let synthesis = deps
        .reason
        .complete(
            SYNTHESIS_PROMPT,
            &format!("Question: {question}\n\n{transcript}"),
        )
        .await?;
    let parsed = extract_json_object(&synthesis).unwrap_or(Value::Null);
    let read = |key: &str| {
        parsed
            .get(key)
            .and_then(Value::as_str)
            .unwrap_or_default()
            .trim()
            .to_owned()
    };

    Ok(CouncilOutcome {
        question: question.to_owned(),
        model: deps.reason.describe(),
        agreement: read("agreement"),
        divergence: read("divergence"),
        crux: read("crux"),
        crux_question: read("crux_question"),
        answers,
    })
}

#[cfg(test)]
mod tests {
    use super::resolve_personas;

    #[test]
    fn the_default_council_is_three_lenses() {
        let personas = resolve_personas(&[]).unwrap();
        assert_eq!(personas.len(), 3);
        assert!(personas.iter().any(|persona| persona.id == "skeptic"));
    }

    #[test]
    fn an_unknown_lens_is_refused_and_so_is_a_council_of_one() {
        assert!(resolve_personas(&["nobody".to_owned()]).is_err());
        assert!(resolve_personas(&["friend".to_owned()]).is_err());
    }
}
