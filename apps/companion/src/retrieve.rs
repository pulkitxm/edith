use std::collections::HashMap;
use std::error::Error;

use chrono::{DateTime, Duration, Utc};
use serde::Serialize;
use serde_json::Value;
use sqlx::PgPool;
use uuid::Uuid;

use crate::embed::EmbedClient;
use crate::indexer::halfvec_literal;
use crate::rerank::RerankClient;

const RRF_K: f64 = 60.0;
const CANDIDATE_LIMIT: i64 = 50;

#[derive(Clone, Debug)]
pub struct RetrievalPolicy {
    pub sources: Vec<String>,
    pub window_days: Option<i64>,
    pub k: usize,
    pub prefer_contradicted: bool,
    pub salience_weight: f64,
    pub beliefs: bool,
    pub observations: bool,
    pub graph: bool,
}

impl Default for RetrievalPolicy {
    fn default() -> Self {
        Self {
            sources: Vec::new(),
            window_days: None,
            k: 8,
            prefer_contradicted: false,
            salience_weight: 0.15,
            beliefs: true,
            observations: true,
            graph: true,
        }
    }
}

#[derive(Clone, Debug, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ItemScores {
    pub vector: Option<f32>,
    pub text: Option<f32>,
    pub graph: Option<f32>,
    pub recency: Option<f32>,
    pub salience: Option<f32>,
    pub rerank: Option<f32>,
    pub fused: f32,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RetrievedItem {
    pub item_type: String,
    pub item_id: Uuid,
    pub episode_id: Option<Uuid>,
    pub title: String,
    pub occurred_at: DateTime<Utc>,
    pub text: String,
    pub text_en: String,
    pub t_start_s: Option<f32>,
    pub t_end_s: Option<f32>,
    pub scores: ItemScores,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RetrievalOutcome {
    pub items: Vec<RetrievedItem>,
    pub candidates: usize,
    pub reranked: bool,
    pub channels: Vec<String>,
}

pub fn reciprocal_rank(rank: usize) -> f64 {
    1.0 / (RRF_K + rank as f64 + 1.0)
}

pub fn recency_score(occurred_at: DateTime<Utc>, now: DateTime<Utc>) -> f32 {
    let days = (now - occurred_at).num_days().max(0) as f64;
    (1.0 / (1.0 + days / 180.0)) as f32
}

fn window_start(policy: &RetrievalPolicy, now: DateTime<Utc>) -> DateTime<Utc> {
    match policy.window_days {
        Some(days) if days > 0 => now - Duration::days(days),
        _ => DateTime::<Utc>::MIN_UTC,
    }
}

type ChunkRow = (
    Uuid,
    Uuid,
    String,
    String,
    String,
    DateTime<Utc>,
    Option<f32>,
    Option<f32>,
    Option<f32>,
);

fn chunk_item(row: &ChunkRow) -> RetrievedItem {
    RetrievedItem {
        item_type: "chunk".to_owned(),
        item_id: row.0,
        episode_id: Some(row.1),
        title: row.4.clone(),
        occurred_at: row.5,
        text: row.2.clone(),
        text_en: row.3.clone(),
        t_start_s: row.6,
        t_end_s: row.7,
        scores: ItemScores {
            salience: row.8,
            ..ItemScores::default()
        },
    }
}

async fn vector_channel(
    pool: &PgPool,
    embed: &EmbedClient,
    query: &str,
    policy: &RetrievalPolicy,
    since: DateTime<Utc>,
) -> Result<Vec<ChunkRow>, Box<dyn Error + Send + Sync>> {
    let embedding = halfvec_literal(&embed.embed(&[query.to_owned()]).await?.remove(0));
    let rows = sqlx::query_as::<_, ChunkRow>(
        "SELECT c.id, c.episode_id, c.text_original, c.text_en, e.title, e.occurred_at, c.t_start_s, c.t_end_s, c.salience FROM chunks c JOIN episodes e ON e.id = c.episode_id WHERE c.embedding IS NOT NULL AND e.occurred_at >= $2 AND ($3::text[] = '{}' OR e.kind = ANY($3)) ORDER BY c.embedding <=> $1::halfvec LIMIT $4",
    )
    .bind(&embedding)
    .bind(since)
    .bind(&policy.sources)
    .bind(CANDIDATE_LIMIT)
    .fetch_all(pool)
    .await?;
    Ok(rows)
}

async fn text_channel(
    pool: &PgPool,
    query: &str,
    policy: &RetrievalPolicy,
    since: DateTime<Utc>,
) -> Result<Vec<ChunkRow>, sqlx::Error> {
    sqlx::query_as::<_, ChunkRow>(
        "SELECT c.id, c.episode_id, c.text_original, c.text_en, e.title, e.occurred_at, c.t_start_s, c.t_end_s, c.salience FROM chunks c JOIN episodes e ON e.id = c.episode_id WHERE (c.tsv @@ websearch_to_tsquery('english', $1) OR c.text_original ILIKE '%' || $1 || '%') AND e.occurred_at >= $2 AND ($3::text[] = '{}' OR e.kind = ANY($3)) ORDER BY ts_rank_cd(c.tsv, websearch_to_tsquery('english', $1)) DESC LIMIT $4",
    )
    .bind(query)
    .bind(since)
    .bind(&policy.sources)
    .bind(CANDIDATE_LIMIT)
    .fetch_all(pool)
    .await
}

async fn graph_channel(
    pool: &PgPool,
    query: &str,
    since: DateTime<Utc>,
) -> Result<Vec<ChunkRow>, sqlx::Error> {
    sqlx::query_as::<_, ChunkRow>(
        "SELECT DISTINCT c.id, c.episode_id, c.text_original, c.text_en, e.title, e.occurred_at, c.t_start_s, c.t_end_s, c.salience FROM entities en JOIN entity_mentions m ON m.entity_id = en.id JOIN episodes e ON e.id = m.episode_id JOIN chunks c ON c.episode_id = e.id WHERE (en.canonical_name ILIKE '%' || $1 || '%' OR EXISTS (SELECT 1 FROM unnest(en.aliases) alias WHERE $1 ILIKE '%' || alias || '%' OR alias ILIKE '%' || $1 || '%')) AND e.occurred_at >= $2 ORDER BY e.occurred_at DESC LIMIT $3",
    )
    .bind(query)
    .bind(since)
    .bind(CANDIDATE_LIMIT / 2)
    .fetch_all(pool)
    .await
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct BeliefHit {
    pub id: Uuid,
    pub statement: String,
    pub confidence: f32,
    pub stability: f32,
    pub corroboration: String,
    pub status: String,
    pub evidence_episode_ids: Vec<Uuid>,
    pub counter_evidence_episode_ids: Vec<Uuid>,
}

pub async fn belief_channel(
    pool: &PgPool,
    embed: &EmbedClient,
    query: &str,
    policy: &RetrievalPolicy,
) -> Result<Vec<BeliefHit>, Box<dyn Error + Send + Sync>> {
    if !policy.beliefs {
        return Ok(Vec::new());
    }
    let embedding = halfvec_literal(&embed.embed(&[query.to_owned()]).await?.remove(0));
    type Row = (Uuid, String, f32, f32, String, String, Vec<Uuid>, Vec<Uuid>);
    let statuses: Vec<String> = if policy.prefer_contradicted {
        vec!["active".to_owned(), "contested".to_owned()]
    } else {
        vec!["active".to_owned()]
    };
    let rows = sqlx::query_as::<_, Row>(
        "SELECT id, statement, confidence, stability, corroboration, status, evidence_episode_ids, counter_evidence_episode_ids FROM beliefs WHERE status = ANY($2) AND embedding IS NOT NULL ORDER BY (1 - (embedding <=> $1::halfvec)) * (0.5 + confidence) * (1 + least(stability, 5) / 10.0) DESC LIMIT 6",
    )
    .bind(&embedding)
    .bind(&statuses)
    .fetch_all(pool)
    .await?;
    Ok(rows
        .into_iter()
        .map(
            |(
                id,
                statement,
                confidence,
                stability,
                corroboration,
                status,
                evidence_episode_ids,
                counter_evidence_episode_ids,
            )| BeliefHit {
                id,
                statement,
                confidence,
                stability,
                corroboration,
                status,
                evidence_episode_ids,
                counter_evidence_episode_ids,
            },
        )
        .collect())
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ObservationHit {
    pub id: Uuid,
    pub source: String,
    pub kind: String,
    pub observed_at: DateTime<Utc>,
    pub payload: Value,
}

pub async fn observation_channel(
    pool: &PgPool,
    query: &str,
    policy: &RetrievalPolicy,
    now: DateTime<Utc>,
) -> Result<Vec<ObservationHit>, sqlx::Error> {
    if !policy.observations {
        return Ok(Vec::new());
    }
    let since = window_start(policy, now);
    type Row = (Uuid, String, String, DateTime<Utc>, Value);
    let rows = sqlx::query_as::<_, Row>(
        "SELECT id, source, kind, observed_at, payload FROM observations WHERE observed_at >= $1 AND ($2::text[] = '{}' OR source = ANY($2)) AND ($3 = '' OR payload::text ILIKE '%' || $3 || '%') ORDER BY observed_at DESC LIMIT 12",
    )
    .bind(since)
    .bind(&policy.sources)
    .bind(longest_word(query))
    .fetch_all(pool)
    .await?;
    if !rows.is_empty() {
        return Ok(rows
            .into_iter()
            .map(|(id, source, kind, observed_at, payload)| ObservationHit {
                id,
                source,
                kind,
                observed_at,
                payload,
            })
            .collect());
    }
    let recent = sqlx::query_as::<_, Row>(
        "SELECT id, source, kind, observed_at, payload FROM observations WHERE observed_at >= $1 AND ($2::text[] = '{}' OR source = ANY($2)) ORDER BY observed_at DESC LIMIT 8",
    )
    .bind(since)
    .bind(&policy.sources)
    .fetch_all(pool)
    .await?;
    Ok(recent
        .into_iter()
        .map(|(id, source, kind, observed_at, payload)| ObservationHit {
            id,
            source,
            kind,
            observed_at,
            payload,
        })
        .collect())
}

pub fn longest_word(query: &str) -> String {
    query
        .split(|character: char| !character.is_alphanumeric())
        .filter(|word| word.len() > 3)
        .max_by_key(|word| word.len())
        .unwrap_or_default()
        .to_lowercase()
}

pub async fn retrieve(
    pool: &PgPool,
    embed: &EmbedClient,
    rerank: &RerankClient,
    query: &str,
    policy: &RetrievalPolicy,
) -> Result<RetrievalOutcome, Box<dyn Error + Send + Sync>> {
    let now = Utc::now();
    let since = window_start(policy, now);
    let mut channels = Vec::new();
    let mut fused: HashMap<Uuid, RetrievedItem> = HashMap::new();
    let mut weights: HashMap<Uuid, f64> = HashMap::new();

    let vector = vector_channel(pool, embed, query, policy, since).await?;
    if !vector.is_empty() {
        channels.push("vector".to_owned());
    }
    for (rank, row) in vector.iter().enumerate() {
        let item = fused.entry(row.0).or_insert_with(|| chunk_item(row));
        item.scores.vector = Some(reciprocal_rank(rank) as f32);
        *weights.entry(row.0).or_insert(0.0) += reciprocal_rank(rank);
    }

    let text = text_channel(pool, query, policy, since).await?;
    if !text.is_empty() {
        channels.push("keyword".to_owned());
    }
    for (rank, row) in text.iter().enumerate() {
        let item = fused.entry(row.0).or_insert_with(|| chunk_item(row));
        item.scores.text = Some(reciprocal_rank(rank) as f32);
        *weights.entry(row.0).or_insert(0.0) += reciprocal_rank(rank);
    }

    if policy.graph {
        let graph = graph_channel(pool, query, since).await.unwrap_or_default();
        if !graph.is_empty() {
            channels.push("graph".to_owned());
        }
        for (rank, row) in graph.iter().enumerate() {
            let item = fused.entry(row.0).or_insert_with(|| chunk_item(row));
            item.scores.graph = Some(reciprocal_rank(rank) as f32);
            *weights.entry(row.0).or_insert(0.0) += reciprocal_rank(rank) * 0.7;
        }
    }

    let candidates = fused.len();
    let mut ranked = fused.into_values().collect::<Vec<_>>();
    for item in &mut ranked {
        let base = weights.get(&item.item_id).copied().unwrap_or(0.0);
        let recency = recency_score(item.occurred_at, now);
        let salience = item.scores.salience.unwrap_or(0.0) as f64;
        item.scores.recency = Some(recency);
        item.scores.fused =
            (base * (1.0 + policy.salience_weight * salience) * (0.85 + 0.15 * recency as f64))
                as f32;
    }
    ranked.sort_by(|left, right| {
        right
            .scores
            .fused
            .partial_cmp(&left.scores.fused)
            .unwrap_or(std::cmp::Ordering::Equal)
    });
    ranked.truncate(CANDIDATE_LIMIT as usize);

    let mut reranked = false;
    if rerank.configured() && ranked.len() > policy.k {
        let documents = ranked
            .iter()
            .map(|item| item.text_en.clone())
            .collect::<Vec<_>>();
        match rerank.scores(query, &documents).await {
            Ok(scores) => {
                for (item, score) in ranked.iter_mut().zip(scores) {
                    item.scores.rerank = Some(score);
                }
                ranked.sort_by(|left, right| {
                    right
                        .scores
                        .rerank
                        .unwrap_or(0.0)
                        .partial_cmp(&left.scores.rerank.unwrap_or(0.0))
                        .unwrap_or(std::cmp::Ordering::Equal)
                });
                reranked = true;
                channels.push("rerank".to_owned());
            }
            Err(error) => eprintln!("rerank skipped: {error}"),
        }
    }

    ranked.truncate(policy.k);
    Ok(RetrievalOutcome {
        items: ranked,
        candidates,
        reranked,
        channels,
    })
}

pub fn evidence_block(
    items: &[RetrievedItem],
    beliefs: &[BeliefHit],
    observations: &[ObservationHit],
) -> String {
    let mut parts = Vec::new();
    if !items.is_empty() {
        let excerpts = items
            .iter()
            .map(|item| {
                let when = item.occurred_at.format("%Y-%m-%d");
                let locator = match (item.t_start_s, item.t_end_s) {
                    (Some(start), Some(end)) => format!(" [{start:.0}s-{end:.0}s]"),
                    _ => String::new(),
                };
                format!(
                    "episode {} ({when}) {}{locator}\n{}",
                    item.episode_id.unwrap_or_default(),
                    item.title,
                    item.text
                )
            })
            .collect::<Vec<_>>()
            .join("\n\n");
        parts.push(format!("Excerpts from what they recorded:\n\n{excerpts}"));
    }
    if !beliefs.is_empty() {
        let lines = beliefs
            .iter()
            .map(|belief| {
                format!(
                    "- ({}, confidence {:.2}, stability {:.0}) {} [belief {}]",
                    belief.corroboration,
                    belief.confidence,
                    belief.stability,
                    belief.statement,
                    belief.id
                )
            })
            .collect::<Vec<_>>()
            .join("\n");
        parts.push(format!(
            "What the system already concluded, each resting on the evidence episodes named in its record:\n{lines}"
        ));
    }
    if !observations.is_empty() {
        let lines = observations
            .iter()
            .map(|observation| {
                format!(
                    "- {} {} {} {}",
                    observation.observed_at.format("%Y-%m-%d %H:%M"),
                    observation.source,
                    observation.kind,
                    observation.payload
                )
            })
            .collect::<Vec<_>>()
            .join("\n");
        parts.push(format!(
            "What independent records show they actually did:\n{lines}"
        ));
    }
    parts.join("\n\n")
}

#[cfg(test)]
mod tests {
    use super::{longest_word, recency_score, reciprocal_rank};
    use chrono::{Duration, Utc};

    #[test]
    fn earlier_ranks_score_higher() {
        assert!(reciprocal_rank(0) > reciprocal_rank(1));
        assert!(reciprocal_rank(1) > reciprocal_rank(40));
    }

    #[test]
    fn recency_decays_but_never_hits_zero() {
        let now = Utc::now();
        let fresh = recency_score(now, now);
        let old = recency_score(now - Duration::days(720), now);
        assert!(fresh > old);
        assert!(old > 0.0);
    }

    #[test]
    fn the_longest_word_is_what_filters_observations() {
        assert_eq!(longest_word("how is warden going"), "warden");
        assert_eq!(longest_word("is it ok"), "");
    }
}
