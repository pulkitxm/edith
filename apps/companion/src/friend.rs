use std::error::Error;

use serde::Serialize;
use serde_json::Value;
use sqlx::PgPool;
use uuid::Uuid;

use crate::ask::{AskCitation, extract_json_object, resolve_support};
use crate::core_memory;
use crate::embed::EmbedClient;
use crate::grounding::{GroundingClient, GroundingReport, verbosity_flag};
use crate::lenses;
use crate::persona::Persona;
use crate::reason::{ReasonClient, ReasonError};
use crate::rerank::RerankClient;
use crate::retrieve::{
    BeliefHit, ObservationHit, RetrievedItem, belief_channel, evidence_block, observation_channel,
    retrieve,
};
use crate::turns::{RetrievedChunk, TurnRecord, latency_since, log_turn_record};

pub const PROMPT_VERSION: &str = "friend-v1";

const REFRAME_PROMPT: &str = "You turn what a person said into the neutral question underneath \
it. Strip the certainty, the framing and any assumption they smuggled in, and keep the subject. \
Answer with the question alone, one sentence, no preamble. If what they said is already a \
neutral question, repeat it unchanged.";

const COUNTERFACTUAL_PROMPT: &str = "Before anyone answers this question, state what the answer \
would be if the opposite premise were true. Two sentences at most, no hedging, no answer to the \
real question. This is a check against agreeing by reflex, not an answer.";

const SCORING_RULE: &str = "You are scored: +1 for a claim the evidence supports, -1 for a claim \
it does not, +0.4 for saying plainly that you do not have enough to judge. Declining to answer \
when the evidence is thin is a good move, and so is having an opinion when the evidence is \
there. Refusing to engage with something you do have evidence for scores worst of all.";

const CRITIC_PROMPT: &str = "You check a draft answer against evidence. You cannot see who asked \
or how they framed it, and that is deliberate: judge only whether each sentence is carried by \
the evidence. Answer with JSON only: {\"verdict\": \"ok\"|\"revise\", \"problems\": [one \
sentence per unsupported or overreaching claim], \"note\": one sentence}. An answer that hedges \
away from a claim the evidence does support is also a problem, name it.";

const OPINION_PROMPT: &str = "You hold one opinion about what this person just said, and its \
whole authority is that you have seen the pattern before. State the pattern, name the evidence \
it rests on, then say what you think. Lead with the observation, not the verdict. Do not assign \
a motive. Three sentences at most. If the belief given does not really bear on what they said, \
answer with an empty string.";

fn answer_contract(persona: &Persona) -> String {
    format!(
        "You answer questions about one person from their own notes, voice memos and records.\n\n\
         {}\n\n{}\n\n{SCORING_RULE}\n\nEvery claim you make must resolve to something you were \
         given. Answer with JSON only: {{\"answer\": string, \"abstain\": bool, \"citations\": \
         [{{\"episodeId\": string, \"quote\": string, \"support\": \"verbatim\"|\"paraphrase\"|\
         \"inference\"}}]}}. Set abstain true when the evidence cannot carry an answer, and put \
         what is missing in answer. Quote in the language they used; do not translate a quote. \
         Cite only episode ids you were given. Keep the answer under {} words.",
        persona.voice_text,
        persona.output_contract(),
        persona.max_words,
    )
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PersonaAnswer {
    pub persona: String,
    pub label: String,
    pub question: String,
    pub reframed: Option<String>,
    pub answer: String,
    pub abstained: bool,
    pub citations: Vec<AskCitation>,
    pub beliefs: Vec<BeliefHit>,
    pub observations: Vec<ObservationHit>,
    pub grounding: GroundingReport,
    pub opinion: Option<String>,
    pub stages: Vec<String>,
    pub chunks_considered: usize,
    pub model: String,
    pub prompt_version: String,
}

pub struct FriendDeps<'a> {
    pub pool: &'a PgPool,
    pub embed: &'a EmbedClient,
    pub rerank: &'a RerankClient,
    pub grounding: &'a GroundingClient,
    pub reason: &'a ReasonClient,
}

pub async fn reframe(reason: &ReasonClient, question: &str) -> Option<String> {
    let answer = reason.complete(REFRAME_PROMPT, question).await.ok()?;
    let reframed = answer
        .lines()
        .map(str::trim)
        .find(|line| line.len() > 5 && !line.starts_with('{'))?
        .trim_matches('"')
        .to_owned();
    if reframed.eq_ignore_ascii_case(question.trim()) {
        return None;
    }
    Some(reframed)
}

pub fn opposite_query(question: &str) -> String {
    format!("evidence that the opposite is true: {question}")
}

async fn tensioning_belief(beliefs: &[BeliefHit]) -> Option<BeliefHit> {
    beliefs
        .iter()
        .filter(|belief| belief.stability >= 2.0 && belief.confidence >= 0.6)
        .max_by(|left, right| {
            (left.stability * left.confidence)
                .partial_cmp(&(right.stability * right.confidence))
                .unwrap_or(std::cmp::Ordering::Equal)
        })
        .cloned()
}

pub async fn answer_with_persona(
    deps: &FriendDeps<'_>,
    persona: &Persona,
    question: &str,
) -> Result<PersonaAnswer, Box<dyn Error + Send + Sync>> {
    if !deps.reason.configured() {
        return Err(Box::new(ReasonError::unconfigured()));
    }
    let started = std::time::Instant::now();
    let mut stages = Vec::new();

    let reframed = if persona.runs("reframe_question") {
        stages.push("reframe_question".to_owned());
        reframe(deps.reason, question).await
    } else {
        None
    };
    let search_query = reframed.as_deref().unwrap_or(question);

    let policy = persona.policy();
    let mut retrieval = retrieve(
        deps.pool,
        deps.embed,
        deps.rerank,
        search_query,
        &policy,
    )
    .await?;
    stages.push("retrieve".to_owned());

    if persona.runs("find_disconfirming") {
        let inverted = retrieve(
            deps.pool,
            deps.embed,
            deps.rerank,
            &opposite_query(search_query),
            &policy,
        )
        .await?;
        for item in inverted.items {
            if !retrieval
                .items
                .iter()
                .any(|existing| existing.item_id == item.item_id)
            {
                retrieval.items.push(item);
            }
        }
        stages.push("find_disconfirming".to_owned());
    }

    let beliefs = belief_channel(deps.pool, deps.embed, search_query, &policy)
        .await
        .unwrap_or_default();
    let observations = observation_channel(deps.pool, search_query, &policy, chrono::Utc::now())
        .await
        .unwrap_or_default();

    let weighted_observations = if persona.evidence.observation_weight <= 0.0 {
        Vec::new()
    } else {
        observations.clone()
    };
    let evidence = evidence_block(&retrieval.items, &beliefs, &weighted_observations);
    if evidence.trim().is_empty() {
        let outcome = PersonaAnswer {
            persona: persona.id.clone(),
            label: persona.label.clone(),
            question: question.to_owned(),
            reframed,
            answer: "There is nothing in the memory yet to answer from.".to_owned(),
            abstained: true,
            citations: Vec::new(),
            beliefs,
            observations,
            grounding: GroundingReport {
                score: 0.0,
                scorer: deps.grounding.describe(),
                unsupported: Vec::new(),
            },
            opinion: None,
            stages,
            chunks_considered: 0,
            model: deps.reason.describe(),
            prompt_version: PROMPT_VERSION.to_owned(),
        };
        return Ok(outcome);
    }

    let core = core_memory::block(deps.pool).await;
    let mut prompt = String::new();
    if !core.is_empty() {
        prompt.push_str(&format!("Who they are right now:\n{core}\n\n"));
    }
    prompt.push_str(&evidence);

    if persona.runs("counterfactual") {
        let counterfactual = deps
            .reason
            .complete(COUNTERFACTUAL_PROMPT, search_query)
            .await
            .unwrap_or_default();
        if !counterfactual.trim().is_empty() {
            prompt.push_str(&format!(
                "\n\nWhat the answer would be under the opposite premise, written before \
                 answering, as a check against agreeing by reflex:\n{}",
                counterfactual.trim()
            ));
            stages.push("counterfactual".to_owned());
        }
    }
    if persona.evidence.require_corroboration {
        prompt.push_str(
            "\n\nThis lens does not accept a claim carried only by their own account. Where the \
             only support is something they said about themselves, say so.",
        );
    }
    prompt.push_str(&format!("\n\nQuestion: {search_query}"));
    if let Some(reframed) = &reframed {
        prompt.push_str(&format!("\n\nThey put it this way: {question}"));
        let _ = reframed;
    }

    let mut system = answer_contract(persona);
    let lens = lenses::load(deps.pool, &persona.id).await;
    if !lens.trim().is_empty() {
        system.push_str(&format!(
            "\n\nWhat this lens has learned about being useful to them:\n{}",
            lens.trim()
        ));
    }
    let raw = deps.reason.complete(&system, &prompt).await?;
    stages.push("draft".to_owned());
    let (mut answer, mut abstained, mut citations) = parse_answer(&raw, &retrieval.items)?;

    let mut grounding = deps.grounding.score(&evidence, &answer).await;
    stages.push("ground_check".to_owned());

    let needs_revision = persona.runs("revise")
        && (grounding.score < persona.abstain_below as f32
            || !grounding.unsupported.is_empty()
            || verbosity_flag(&answer, persona.max_words));
    if needs_revision {
        let critique_input = format!(
            "Evidence:\n{evidence}\n\nDraft answer:\n{answer}\n\nGrounding score {:.2} from {}. \
             Sentences the scorer could not tie to the evidence:\n{}",
            grounding.score,
            grounding.scorer,
            if grounding.unsupported.is_empty() {
                "none".to_owned()
            } else {
                grounding.unsupported.join("\n")
            }
        );
        let critique = deps
            .reason
            .complete(CRITIC_PROMPT, &critique_input)
            .await
            .unwrap_or_default();
        let problems = extract_json_object(&critique)
            .and_then(|value| {
                value.get("problems").and_then(Value::as_array).map(|items| {
                    items
                        .iter()
                        .filter_map(Value::as_str)
                        .map(str::to_owned)
                        .collect::<Vec<_>>()
                })
            })
            .unwrap_or_default();
        if !problems.is_empty() || verbosity_flag(&answer, persona.max_words) {
            let revise_input = format!(
                "{prompt}\n\nA critic that cannot see how the question was framed found these \
                 problems with your draft:\n{}\n\nYour draft:\n{answer}\n\nAnswer again, fixing \
                 exactly these and keeping everything the evidence does carry.",
                problems.join("\n")
            );
            if let Ok(second) = deps.reason.complete(&system, &revise_input).await
                && let Ok((revised, revised_abstain, revised_citations)) =
                    parse_answer(&second, &retrieval.items)
            {
                answer = revised;
                abstained = revised_abstain;
                citations = revised_citations;
                grounding = deps.grounding.score(&evidence, &answer).await;
            }
        }
        stages.push("revise".to_owned());
    }

    if !abstained && grounding.score < persona.abstain_below as f32 && citations.is_empty() {
        abstained = true;
        answer = format!(
            "I do not have enough in your record to answer that one honestly. {answer}"
        );
    }

    let opinion = match tensioning_belief(&beliefs).await {
        Some(belief) if !abstained => {
            let input = format!(
                "They said: {question}\n\nA belief you hold about them, formed from episodes {}: \
                 {}\n\nEvidence:\n{evidence}",
                belief
                    .evidence_episode_ids
                    .iter()
                    .map(Uuid::to_string)
                    .collect::<Vec<_>>()
                    .join(", "),
                belief.statement
            );
            deps.reason
                .complete(OPINION_PROMPT, &input)
                .await
                .ok()
                .map(|value| value.trim().to_owned())
                .filter(|value| value.len() > 20)
        }
        _ => None,
    };

    let logged = retrieval
        .items
        .iter()
        .enumerate()
        .map(|(rank, item)| {
            let cited = citations
                .iter()
                .any(|citation| Some(citation.episode_id) == item.episode_id);
            RetrievedChunk::from_item(item, rank as i32 + 1, cited)
        })
        .collect::<Vec<_>>();
    let model = deps.reason.describe();
    log_turn_record(
        deps.pool,
        TurnRecord {
            kind: "persona",
            query: question,
            model: Some(&model),
            persona: Some(&persona.id),
            prompt_version: Some(PROMPT_VERSION),
            grounding_score: Some(grounding.score),
            abstained,
            latency_ms: latency_since(started),
        },
        &logged,
    )
    .await;

    Ok(PersonaAnswer {
        persona: persona.id.clone(),
        label: persona.label.clone(),
        question: question.to_owned(),
        reframed,
        answer,
        abstained,
        citations,
        beliefs,
        observations,
        grounding,
        opinion,
        stages,
        chunks_considered: retrieval.items.len(),
        model,
        prompt_version: PROMPT_VERSION.to_owned(),
    })
}

type ParsedAnswer = (String, bool, Vec<AskCitation>);

fn parse_answer(
    raw: &str,
    items: &[RetrievedItem],
) -> Result<ParsedAnswer, Box<dyn Error + Send + Sync>> {
    let Some(parsed) = extract_json_object(raw) else {
        return Err(format!("answer had no JSON object: {raw}").into());
    };
    let answer = parsed
        .get("answer")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|answer| !answer.is_empty())
        .ok_or("answer had no answer field")?
        .to_owned();
    let abstained = parsed
        .get("abstain")
        .and_then(Value::as_bool)
        .unwrap_or(false);

    let mut citations = Vec::new();
    for citation in parsed
        .get("citations")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
    {
        let Some(episode_id) = citation
            .get("episodeId")
            .and_then(Value::as_str)
            .and_then(|value| Uuid::parse_str(value).ok())
        else {
            continue;
        };
        let Some(item) = items
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
            occurred_at: item
                .occurred_at
                .to_rfc3339_opts(chrono::SecondsFormat::AutoSi, true),
        });
    }
    Ok((answer, abstained, citations))
}

#[cfg(test)]
mod tests {
    use super::{answer_contract, opposite_query};
    use crate::persona::find;

    #[test]
    fn the_contract_carries_the_word_cap_and_the_scoring_rule() {
        let skeptic = find("skeptic").unwrap();
        let contract = answer_contract(&skeptic);
        assert!(contract.contains("under 200 words"));
        assert!(contract.contains("+0.4"));
        assert!(contract.contains("argue the other side"));
    }

    #[test]
    fn the_inverted_query_asks_for_the_opposite() {
        assert!(opposite_query("am I doing well").starts_with("evidence that the opposite"));
    }
}
