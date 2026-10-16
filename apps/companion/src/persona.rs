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
    let mut persona = serde_saphyr::from_str_with_options::<Persona>(
        spec,
        serde_saphyr::options! {
            strict_booleans: true,
            merge_keys: serde_saphyr::MergeKeyPolicy::AsOrdinary,
            with_snippet: false,
        },
    )
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
    use super::{BUILT_IN, all, default_persona, find, parse};

    #[test]
    fn the_four_starter_lenses_load() {
        let personas = all();
        let ids = personas
            .iter()
            .map(|persona| persona.id.as_str())
            .collect::<Vec<_>>();
        assert_eq!(ids, vec!["analyst", "coach", "friend", "skeptic"]);
        assert!(
            personas
                .iter()
                .all(|persona| !persona.voice_text.is_empty())
        );
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

    #[test]
    fn yaml_personas_preserve_aliases_defaults_and_voice() {
        let spec = "id: sample\nretrieval: {window_days: 12, salience_weight: 0.4, beliefs: false}\nevidence: {self_report_weight: 0.3, observation_weight: 0.8, require_corroboration: true}\nabstain_below: 0.6\nmax_words: 180\n";
        let persona = parse("sample", spec, "  sample voice  ").unwrap();
        assert_eq!(persona.label, "Sample");
        assert_eq!(persona.retrieval.window_days, Some(12));
        assert_eq!(persona.retrieval.salience_weight, Some(0.4));
        assert_eq!(persona.retrieval.k, 8);
        assert!(!persona.retrieval.beliefs);
        assert!(persona.retrieval.observations && persona.retrieval.graph);
        assert_eq!(persona.evidence.self_report_weight, 0.3);
        assert_eq!(persona.evidence.observation_weight, 0.8);
        assert!(persona.evidence.require_corroboration);
        assert_eq!(persona.abstain_below, 0.6);
        assert_eq!(persona.max_words, 180);
        assert_eq!(persona.voice_text, "sample voice");
    }

    #[test]
    fn built_in_yaml_personas_keep_their_policies_without_environment_reads() {
        let expected = [
            ("analyst", 365, 10, 0.3, 1.0, false, "findings", 220),
            ("friend", 1095, 12, 1.0, 0.4, false, "prose", 200),
            ("coach", 30, 10, 0.6, 1.0, false, "action", 160),
            ("skeptic", 90, 20, 0.2, 1.0, true, "findings", 200),
        ];
        for ((id, spec, voice), expected) in BUILT_IN.into_iter().zip(expected) {
            let persona = parse(id, spec, voice).unwrap();
            assert_eq!(persona.id, expected.0);
            assert_eq!(persona.retrieval.window_days, Some(expected.1));
            assert_eq!(persona.retrieval.k, expected.2);
            assert_eq!(persona.evidence.self_report_weight, expected.3);
            assert_eq!(persona.evidence.observation_weight, expected.4);
            assert_eq!(persona.evidence.require_corroboration, expected.5);
            assert_eq!(persona.output, expected.6);
            assert_eq!(persona.max_words, expected.7);
            assert_eq!(persona.voice_text, voice.trim());
        }
    }

    #[test]
    fn yaml_personas_preserve_camel_case_settings() {
        let snake = "id: sample\nretrieval: {window_days: 12, salience_weight: 0.4}\nevidence: {self_report_weight: 0.3, observation_weight: 0.8, require_corroboration: true}\nabstain_below: 0.6\nmax_words: 180\n";
        let camel = "id: sample\nretrieval: {windowDays: 12, salienceWeight: 0.4}\nevidence: {selfReportWeight: 0.3, observationWeight: 0.8, requireCorroboration: true}\nabstainBelow: 0.6\nmaxWords: 180\n";
        let snake = parse("sample", snake, "sample voice").unwrap();
        let camel = parse("sample", camel, "sample voice").unwrap();
        assert_eq!(
            serde_json::to_value(snake).unwrap(),
            serde_json::to_value(camel).unwrap()
        );
    }

    #[test]
    fn yaml_personas_preserve_anchors_and_literal_strings() {
        let spec = "id: sample\nlabel: false\nretrieval: {sources: [&source sample, *source]}\nevidence: {}\nvoice: |\n  ${SYNTHETIC_PERSONA_SECRET}\n  !include synthetic.yaml\n";
        let persona = parse("sample", spec, "  injected voice  ").unwrap();
        assert_eq!(persona.label, "false");
        assert_eq!(persona.retrieval.sources, vec!["sample", "sample"]);
        assert_eq!(
            persona.voice,
            "${SYNTHETIC_PERSONA_SECRET}\n!include synthetic.yaml\n"
        );
        assert_eq!(persona.voice_text, "injected voice");
        let tagged = "id: sample\nretrieval: {}\nevidence: {}\nvoice: !include synthetic-persona-file.yaml\n";
        assert_eq!(
            parse("sample", tagged, "").unwrap().voice,
            "synthetic-persona-file.yaml"
        );
    }

    #[test]
    fn yaml_personas_do_not_implicitly_apply_merge_keys() {
        let spec = "id: sample\nretrieval: {<<: {k: 21}, beliefs: false}\nevidence: {}\n";
        let persona = parse("sample", spec, "").unwrap();
        assert_eq!(persona.retrieval.k, 8);
        assert!(!persona.retrieval.beliefs);
    }

    #[test]
    fn yaml_personas_reject_invalid_types_duplicates_and_documents() {
        for spec in [
            "id: broken\nretrieval: {beliefs: yes}\nevidence: {}\n",
            "id: broken\nretrieval: {k: invalid}\nevidence: {}\n",
            "id: broken\nretrieval: {k: 4, k: 8}\nevidence: {}\n",
            "id: broken\nretrieval: {}\nevidence: {}\nmax_words: 120\nmax_words: 240\n",
            "id: broken\nretrieval: [\nevidence: {}\n",
            "id: broken\nretrieval: {}\n",
            "id: broken\nretrieval: {}\nevidence: {}\n---\nid: extra\nretrieval: {}\nevidence: {}\n",
        ] {
            assert!(parse("broken", spec, "").is_err());
        }
    }

    #[test]
    fn yaml_errors_do_not_render_source_snippets() {
        let spec =
            "id: broken\nlabel: SYNTHETIC_PRIVATE_PERSONA_LABEL\nretrieval: [\nevidence: {}\n";
        let error = parse("broken", spec, "").unwrap_err();
        assert!(error.starts_with("persona broken is not valid YAML:"));
        assert!(!error.contains("SYNTHETIC_PRIVATE_PERSONA_LABEL"));
        assert!(!error.contains("retrieval: ["));
    }
}
