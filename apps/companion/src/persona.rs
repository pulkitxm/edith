use std::env;
use std::fs;
use std::path::PathBuf;

use serde::{Deserialize, Serialize};

use crate::retrieve::RetrievalPolicy;

const BUILT_IN: [(&str, &str, &str); 4] = [
    (
        "analyst",
        include_str!("../personas/analyst.yaml"),
        include_str!("../prompts/personas/analyst.md"),
    ),
    (
        "friend",
        include_str!("../personas/friend.yaml"),
        include_str!("../prompts/personas/friend.md"),
    ),
    (
        "coach",
        include_str!("../personas/coach.yaml"),
        include_str!("../prompts/personas/coach.md"),
    ),
    (
        "skeptic",
        include_str!("../personas/skeptic.yaml"),
        include_str!("../prompts/personas/skeptic.md"),
    ),
];

pub const STAGES: [&str; 7] = [
    "reframe_question",
    "retrieve",
    "counterfactual",
    "find_disconfirming",
    "draft",
    "ground_check",
    "revise",
];

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RetrievalSpec {
    #[serde(default)]
    pub sources: Vec<String>,
    #[serde(default, alias = "window_days")]
    pub window_days: Option<i64>,
    #[serde(default = "default_k")]
    pub k: usize,
    #[serde(default)]
    pub prefer: String,
    #[serde(default, alias = "salience_weight")]
    pub salience_weight: Option<f64>,
    #[serde(default = "default_true")]
    pub beliefs: bool,
    #[serde(default = "default_true")]
    pub observations: bool,
    #[serde(default = "default_true")]
    pub graph: bool,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct EvidenceSpec {
    #[serde(default = "default_weight", alias = "self_report_weight")]
    pub self_report_weight: f64,
    #[serde(default = "default_weight", alias = "observation_weight")]
    pub observation_weight: f64,
    #[serde(default, alias = "require_corroboration")]
    pub require_corroboration: bool,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Persona {
    pub id: String,
    #[serde(default)]
    pub label: String,
    pub retrieval: RetrievalSpec,
    pub evidence: EvidenceSpec,
    #[serde(default)]
    pub pipeline: Vec<String>,
    #[serde(default)]
    pub output: String,
    #[serde(default = "default_abstain", alias = "abstain_below")]
    pub abstain_below: f64,
    #[serde(default = "default_words", alias = "max_words")]
    pub max_words: usize,
    #[serde(default)]
    pub voice: String,
    #[serde(default, skip_deserializing)]
    pub voice_text: String,
}

fn default_k() -> usize {
    8
}

fn default_true() -> bool {
    true
}

fn default_weight() -> f64 {
    1.0
}

fn default_abstain() -> f64 {
    0.5
}

fn default_words() -> usize {
    220
}

impl Persona {
    pub fn policy(&self) -> RetrievalPolicy {
        RetrievalPolicy {
            sources: self.retrieval.sources.clone(),
            window_days: self.retrieval.window_days,
            k: self.retrieval.k.clamp(1, 40),
            prefer_contradicted: self.retrieval.prefer == "contradicted",
            salience_weight: self.retrieval.salience_weight.unwrap_or(0.15),
            beliefs: self.retrieval.beliefs,
            observations: self.retrieval.observations,
            graph: self.retrieval.graph,
        }
    }

    pub fn runs(&self, stage: &str) -> bool {
        if self.pipeline.is_empty() {
            return matches!(stage, "retrieve" | "draft" | "ground_check" | "revise");
        }
        self.pipeline.iter().any(|entry| entry == stage)
    }

    pub fn output_contract(&self) -> &str {
        match self.output.as_str() {
            "findings" => {
                "Write findings: each a single sentence stating one thing the record shows, \
                 strongest first."
            }
            "action" => {
                "Write two or three sentences on what the record shows, then exactly one next \
                 action on its own final line, beginning with 'Next: '."
            }
            _ => "Write plain prose, no headings and no bullet lists.",
        }
    }
}

pub fn persona_dir() -> Option<PathBuf> {
    env::var("PERSONA_DIR").ok().map(PathBuf::from)
}

pub fn parse(id: &str, spec: &str, voice: &str) -> Result<Persona, String> {
    let mut persona = serde_yaml_ng::from_str::<Persona>(spec)
        .map_err(|error| format!("persona {id} is not valid YAML: {error}"))?;
    if persona.label.is_empty() {
        persona.label = title_case(&persona.id);
    }
    for stage in &persona.pipeline {
        if !STAGES.contains(&stage.as_str()) {
            return Err(format!("persona {id} names an unknown stage {stage}"));
        }
    }
    persona.voice_text = voice.trim().to_owned();
    Ok(persona)
}

pub fn title_case(value: &str) -> String {
    let mut characters = value.chars();
    match characters.next() {
        Some(first) => first.to_uppercase().collect::<String>() + characters.as_str(),
        None => String::new(),
    }
}

pub fn all() -> Vec<Persona> {
    let mut personas = Vec::new();
    for (id, spec, voice) in BUILT_IN {
        match parse(id, spec, voice) {
            Ok(persona) => personas.push(persona),
            Err(error) => eprintln!("{error}"),
        }
    }
    if let Some(dir) = persona_dir() {
        let entries = fs::read_dir(&dir).into_iter().flatten().flatten();
        for entry in entries {
            let path = entry.path();
            if path.extension().and_then(|value| value.to_str()) != Some("yaml") {
                continue;
            }
            let Ok(spec) = fs::read_to_string(&path) else {
                continue;
            };
            let id = path
                .file_stem()
                .map(|stem| stem.to_string_lossy().into_owned())
                .unwrap_or_default();
            let voice = fs::read_to_string(dir.join(format!("{id}.md"))).unwrap_or_default();
            match parse(&id, &spec, &voice) {
                Ok(persona) => {
                    personas.retain(|existing| existing.id != persona.id);
                    personas.push(persona);
                }
                Err(error) => eprintln!("{error}"),
            }
        }
    }
    personas.sort_by(|left, right| left.id.cmp(&right.id));
    personas
}

pub fn find(id: &str) -> Option<Persona> {
    all().into_iter().find(|persona| persona.id == id)
}

pub fn default_persona() -> Persona {
    find("friend").unwrap_or_else(|| {
        parse("friend", BUILT_IN[1].1, BUILT_IN[1].2).expect("the built-in friend persona parses")
    })
}

#[cfg(test)]
mod tests {
    use super::{all, default_persona, find, parse};

    #[test]
    fn the_four_starter_lenses_load() {
        let personas = all();
        let ids = personas
            .iter()
            .map(|persona| persona.id.as_str())
            .collect::<Vec<_>>();
        assert_eq!(ids, vec!["analyst", "coach", "friend", "skeptic"]);
        assert!(personas.iter().all(|persona| !persona.voice_text.is_empty()));
    }

    #[test]
    fn the_skeptic_seeks_disconfirming_evidence() {
        let skeptic = find("skeptic").unwrap();
        assert!(skeptic.policy().prefer_contradicted);
        assert!(skeptic.runs("find_disconfirming"));
        assert!(skeptic.runs("counterfactual"));
        assert!(skeptic.evidence.self_report_weight < skeptic.evidence.observation_weight);
        assert!(skeptic.abstain_below > default_persona().abstain_below);
    }

    #[test]
    fn the_friend_does_not_argue_the_other_side() {
        let friend = find("friend").unwrap();
        assert!(!friend.runs("counterfactual"));
        assert!(friend.policy().salience_weight > 0.2);
    }

    #[test]
    fn an_unknown_stage_is_rejected() {
        let spec = "id: broken\nretrieval: {k: 4}\nevidence: {}\npipeline: [teleport]\n";
        assert!(parse("broken", spec, "").is_err());
    }
}
