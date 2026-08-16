use std::error::Error;

use chrono::{DateTime, Utc};
use serde::Serialize;
use serde_json::Value;
use sqlx::PgPool;
use uuid::Uuid;

use crate::reason::{ReasonClient, ReasonError, extract_json_array};

pub const DAILY_BUDGET: i64 = 3;

const ONBOARDING: [(&str, &str, &str, i16); 6] = [
    (
        "Who are the people you actually talk to about how things are going?",
        "Names the relationships every later belief about your life will hang off, and nothing in the record supplies them.",
        "relationships",
        1,
    ),
    (
        "What are you working on right now that matters most to you?",
        "Anchors what counts as a good week; without it the record cannot tell important work from busy work.",
        "work",
        0,
    ),
    (
        "How do you know when a week has gone well?",
        "Gives a standard to judge your own account against, rather than judging it by volume of activity.",
        "work",
        0,
    ),
    (
        "What do you want more of a year from now?",
        "Sets the direction that makes a pattern worth pointing out rather than merely true.",
        "direction",
        1,
    ),
    (
        "What kinds of things do you not want me to bring up?",
        "Fills the permanent do-not-ask list before anything gets asked that should not have been.",
        "boundaries",
        0,
    ),
    (
        "Are you happy with where you are at work, money included?",
        "Unlocks a whole class of reasoning about tradeoffs, and it is worth asking once, well, rather than circling.",
        "work",
        2,
    ),
];

const GENERATE_PROMPT: &str = "You find the holes in a system's model of one person and turn the \
biggest ones into questions worth asking. A question earns its place only if you can say what \
you expect to learn and which belief or theory the answer moves. Answer with a JSON array only. \
Each item: {\"question\": one question, in plain speech, \"motive\": what you expect to learn \
and what it moves, \"topic\": short topic word, \"sensitivity\": 0 for ordinary, 1 for personal, \
2 for money, health or relationships, \"expectedGain\": number 0..1}. One to four questions. \
Never ask what the record already answers, and never ask two things in one sentence.";

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct QuestionRow {
    pub id: Uuid,
    pub question: String,
    pub motive: String,
    pub topic: String,
    pub target_kind: String,
    pub target_id: Option<Uuid>,
    pub expected_gain: f32,
    pub sensitivity: i16,
    pub status: String,
    pub created_at: DateTime<Utc>,
    pub asked_at: Option<DateTime<Utc>>,
    pub answered_at: Option<DateTime<Utc>>,
    pub resolution: Option<String>,
}

#[derive(Debug, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct InquiryOutcome {
    pub proposed: usize,
    pub onboarding_seeded: usize,
    pub suppressed: usize,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AnswerOutcome {
    pub question: String,
    pub episode_id: Uuid,
    pub resolution: String,
    pub asked_today: i64,
}

pub async fn seed_onboarding(pool: &PgPool) -> Result<usize, sqlx::Error> {
    let existing = sqlx::query_scalar::<_, i64>(
        "SELECT count(*) FROM open_questions WHERE target_kind = 'onboarding'",
    )
    .fetch_one(pool)
    .await?;
    if existing > 0 {
        return Ok(0);
    }
    let mut seeded = 0;
    for (index, (question, motive, topic, sensitivity)) in ONBOARDING.iter().enumerate() {
        sqlx::query(
            "INSERT INTO open_questions (question, motive, target_kind, topic, expected_gain, sensitivity) VALUES ($1, $2, 'onboarding', $3, $4, $5)",
        )
        .bind(question)
        .bind(motive)
        .bind(topic)
        .bind(0.95 - index as f32 * 0.01)
        .bind(sensitivity)
        .execute(pool)
        .await?;
        seeded += 1;
    }
    Ok(seeded)
}

pub async fn asked_today(pool: &PgPool) -> Result<i64, sqlx::Error> {
    sqlx::query_scalar::<_, i64>(
        "SELECT count(*) FROM open_questions WHERE asked_at >= date_trunc('day', now())",
    )
    .fetch_one(pool)
    .await
}

pub async fn allowed_sensitivity(pool: &PgPool) -> Result<i16, sqlx::Error> {
    let answered = sqlx::query_scalar::<_, i64>(
        "SELECT count(*) FROM open_questions WHERE status = 'answered'",
    )
    .fetch_one(pool)
    .await?;
    Ok(match answered {
        count if count >= 12 => 2,
        count if count >= 4 => 1,
        _ => 0,
    })
}

pub async fn next(pool: &PgPool) -> Result<Option<QuestionRow>, sqlx::Error> {
    if asked_today(pool).await? >= DAILY_BUDGET {
        return Ok(None);
    }
    let ceiling = allowed_sensitivity(pool).await?;
    type Row = (
        Uuid,
        String,
        String,
        String,
        String,
        Option<Uuid>,
        f32,
        i16,
        String,
        DateTime<Utc>,
        Option<DateTime<Utc>>,
        Option<DateTime<Utc>>,
        Option<String>,
    );
    let row = sqlx::query_as::<_, Row>(
        "SELECT id, question, motive, topic, target_kind, target_id, expected_gain, sensitivity, status, created_at, asked_at, answered_at, resolution FROM open_questions WHERE status = 'pending' AND sensitivity <= $1 AND topic NOT IN (SELECT topic FROM muted_topics) ORDER BY expected_gain DESC, created_at LIMIT 1",
    )
    .bind(ceiling)
    .fetch_optional(pool)
    .await?;
    Ok(row.map(|row| QuestionRow {
        id: row.0,
        question: row.1,
        motive: row.2,
        topic: row.3,
        target_kind: row.4,
        target_id: row.5,
        expected_gain: row.6,
        sensitivity: row.7,
        status: row.8,
        created_at: row.9,
        asked_at: row.10,
        answered_at: row.11,
        resolution: row.12,
    }))
}

pub async fn mark_asked(pool: &PgPool, id: Uuid) -> Result<(), sqlx::Error> {
    sqlx::query("UPDATE open_questions SET status = 'asked', asked_at = now() WHERE id = $1")
        .bind(id)
        .execute(pool)
        .await?;
    Ok(())
}

pub async fn list(pool: &PgPool, limit: i64) -> Result<Vec<QuestionRow>, sqlx::Error> {
    type Row = (
        Uuid,
        String,
        String,
        String,
        String,
        Option<Uuid>,
        f32,
        i16,
        String,
        DateTime<Utc>,
        Option<DateTime<Utc>>,
        Option<DateTime<Utc>>,
        Option<String>,
    );
    let rows = sqlx::query_as::<_, Row>(
        "SELECT id, question, motive, topic, target_kind, target_id, expected_gain, sensitivity, status, created_at, asked_at, answered_at, resolution FROM open_questions ORDER BY (status = 'pending') DESC, expected_gain DESC LIMIT $1",
    )
    .bind(limit)
    .fetch_all(pool)
    .await?;
    Ok(rows
        .into_iter()
        .map(|row| QuestionRow {
            id: row.0,
            question: row.1,
            motive: row.2,
            topic: row.3,
            target_kind: row.4,
            target_id: row.5,
            expected_gain: row.6,
            sensitivity: row.7,
            status: row.8,
            created_at: row.9,
            asked_at: row.10,
            answered_at: row.11,
            resolution: row.12,
        })
        .collect())
}

pub async fn mute(pool: &PgPool, topic: &str) -> Result<i64, sqlx::Error> {
    sqlx::query("INSERT INTO muted_topics (topic) VALUES ($1) ON CONFLICT (topic) DO NOTHING")
        .bind(topic)
        .execute(pool)
        .await?;
    let suppressed = sqlx::query(
        "UPDATE open_questions SET status = 'suppressed' WHERE topic = $1 AND status = 'pending'",
    )
    .bind(topic)
    .execute(pool)
    .await?;
    Ok(suppressed.rows_affected() as i64)
}

pub async fn muted(pool: &PgPool) -> Result<Vec<String>, sqlx::Error> {
    sqlx::query_scalar::<_, String>("SELECT topic FROM muted_topics ORDER BY topic")
        .fetch_all(pool)
        .await
}

pub async fn answer(
    pool: &PgPool,
    id: Uuid,
    text: &str,
) -> Result<AnswerOutcome, Box<dyn Error + Send + Sync>> {
    let Some((question, target_kind, target_id)) =
        sqlx::query_as::<_, (String, String, Option<Uuid>)>(
            "SELECT question, target_kind, target_id FROM open_questions WHERE id = $1",
        )
        .bind(id)
        .fetch_optional(pool)
        .await?
    else {
        return Err("no such question".into());
    };

    let body = format!("{question}\n\n{text}");
    let sha = hex::encode(<sha2::Sha256 as sha2::Digest>::digest(body.as_bytes()));
    let source_id = sqlx::query_scalar::<_, Uuid>(
        "INSERT INTO sources (kind, uri, sha256, bytes) VALUES ('inquiry', $1, $2, $3) ON CONFLICT (sha256) DO UPDATE SET uri = EXCLUDED.uri RETURNING id",
    )
    .bind(format!("inquiry://{id}"))
    .bind(&sha)
    .bind(body.len() as i64)
    .fetch_one(pool)
    .await?;
    let episode_id = sqlx::query_scalar::<_, Uuid>(
        "INSERT INTO episodes (source_id, occurred_at, kind, title, body_original) VALUES ($1, now(), 'inquiry', $2, $3) RETURNING id",
    )
    .bind(source_id)
    .bind(&question)
    .bind(&body)
    .fetch_one(pool)
    .await?;

    let resolution = match (target_kind.as_str(), target_id) {
        ("belief", Some(target)) => {
            sqlx::query("UPDATE beliefs SET status = 'active', last_confirmed = now() WHERE id = $1 AND status = 'contested'")
                .bind(target)
                .execute(pool)
                .await?;
            "that settles a belief the system had marked contested".to_owned()
        }
        ("hypothesis", Some(target)) => {
            sqlx::query("UPDATE hypotheses SET last_tested_at = now() WHERE id = $1")
                .bind(target)
                .execute(pool)
                .await?;
            "that feeds a theory the system is still testing".to_owned()
        }
        ("onboarding", _) => "that fills a standing gap in what the system knows about you".to_owned(),
        _ => "that goes into the memory as an episode like anything else you record".to_owned(),
    };

    sqlx::query(
        "UPDATE open_questions SET status = 'answered', answered_at = now(), answer_episode_id = $2, resolution = $3 WHERE id = $1",
    )
    .bind(id)
    .bind(episode_id)
    .bind(&resolution)
    .execute(pool)
    .await?;

    Ok(AnswerOutcome {
        question,
        episode_id,
        resolution,
        asked_today: asked_today(pool).await?,
    })
}

pub async fn skip(pool: &PgPool, id: Uuid) -> Result<bool, sqlx::Error> {
    let updated = sqlx::query("UPDATE open_questions SET status = 'skipped' WHERE id = $1")
        .bind(id)
        .execute(pool)
        .await?;
    Ok(updated.rows_affected() > 0)
}

pub async fn rank(
    pool: &PgPool,
    reason: &ReasonClient,
) -> Result<InquiryOutcome, Box<dyn Error + Send + Sync>> {
    let mut outcome = InquiryOutcome {
        onboarding_seeded: seed_onboarding(pool).await?,
        ..InquiryOutcome::default()
    };
    outcome.suppressed = suppress_ignored(pool).await? as usize;
    if !reason.configured() {
        return Err(Box::new(ReasonError::unconfigured()));
    }

    let contested = sqlx::query_as::<_, (Uuid, String)>(
        "SELECT id, statement FROM beliefs WHERE status = 'contested' ORDER BY last_confirmed DESC LIMIT 8",
    )
    .fetch_all(pool)
    .await?;
    let testing = sqlx::query_as::<_, (Uuid, String, String)>(
        "SELECT id, statement, mechanism FROM hypotheses WHERE status IN ('proposed', 'testing') ORDER BY formed_at DESC LIMIT 8",
    )
    .fetch_all(pool)
    .await?;
    let thin = sqlx::query_as::<_, (String, i32)>(
        "SELECT canonical_name, mention_count FROM entities WHERE mention_count >= 3 ORDER BY mention_count DESC LIMIT 10",
    )
    .fetch_all(pool)
    .await
    .unwrap_or_default();
    let pending = sqlx::query_scalar::<_, String>(
        "SELECT question FROM open_questions WHERE status IN ('pending', 'asked') LIMIT 20",
    )
    .fetch_all(pool)
    .await?;

    if contested.is_empty() && testing.is_empty() && thin.is_empty() {
        return Ok(outcome);
    }

    let material = format!(
        "Beliefs the system cannot settle:\n{}\n\nTheories it is still testing:\n{}\n\nPeople and projects it hears about often but knows thinly:\n{}\n\nQuestions already queued, do not repeat these:\n{}",
        render(&contested.iter().map(|(_, statement)| statement.clone()).collect::<Vec<_>>()),
        render(&testing.iter().map(|(_, statement, mechanism)| format!("{statement} (because {mechanism})")).collect::<Vec<_>>()),
        render(&thin.iter().map(|(name, count)| format!("{name}, mentioned {count} times")).collect::<Vec<_>>()),
        render(&pending),
    );
    let answer = reason.complete(GENERATE_PROMPT, &material).await?;
    let Some(candidates) = extract_json_array(&answer) else {
        return Ok(outcome);
    };

    for candidate in candidates.as_array().into_iter().flatten() {
        let Some(question) = candidate
            .get("question")
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|question| question.len() > 10 && question.ends_with('?'))
        else {
            continue;
        };
        let Some(motive) = candidate
            .get("motive")
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|motive| motive.len() > 15)
        else {
            continue;
        };
        let topic = candidate
            .get("topic")
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|topic| !topic.is_empty())
            .unwrap_or("general")
            .to_lowercase();
        let sensitivity = candidate
            .get("sensitivity")
            .and_then(Value::as_i64)
            .unwrap_or(0)
            .clamp(0, 2) as i16;
        let expected_gain = candidate
            .get("expectedGain")
            .and_then(Value::as_f64)
            .unwrap_or(0.5)
            .clamp(0.0, 1.0) as f32;
        let (target_kind, target_id) = match (contested.first(), testing.first()) {
            (Some((id, _)), _) if question.len() % 2 == 0 => ("belief", Some(*id)),
            (_, Some((id, _, _))) => ("hypothesis", Some(*id)),
            (Some((id, _)), None) => ("belief", Some(*id)),
            _ => ("gap", None),
        };
        let inserted = sqlx::query(
            "INSERT INTO open_questions (question, motive, target_kind, target_id, topic, expected_gain, sensitivity) SELECT $1, $2, $3, $4, $5, $6, $7 WHERE NOT EXISTS (SELECT 1 FROM open_questions q WHERE lower(q.question) = lower($1)) AND NOT EXISTS (SELECT 1 FROM muted_topics m WHERE m.topic = $5)",
        )
        .bind(question)
        .bind(motive)
        .bind(target_kind)
        .bind(target_id)
        .bind(&topic)
        .bind(expected_gain)
        .bind(sensitivity)
        .execute(pool)
        .await?;
        outcome.proposed += inserted.rows_affected() as usize;
    }
    Ok(outcome)
}

pub async fn suppress_ignored(pool: &PgPool) -> Result<u64, sqlx::Error> {
    let suppressed = sqlx::query(
        "UPDATE open_questions SET status = 'suppressed' WHERE status = 'pending' AND topic IN (SELECT topic FROM open_questions WHERE status = 'skipped' GROUP BY topic HAVING count(*) >= 3)",
    )
    .execute(pool)
    .await?;
    Ok(suppressed.rows_affected())
}

fn render(values: &[String]) -> String {
    if values.is_empty() {
        return "- none".to_owned();
    }
    values
        .iter()
        .map(|value| format!("- {value}"))
        .collect::<Vec<_>>()
        .join("\n")
}

#[cfg(test)]
mod tests {
    use super::{DAILY_BUDGET, ONBOARDING, render};

    #[test]
    fn the_budget_is_small_enough_to_force_a_choice() {
        const { assert!(DAILY_BUDGET <= 3) };
    }

    #[test]
    fn every_onboarding_question_says_why_it_is_asked() {
        assert!(ONBOARDING.iter().all(|(_, motive, _, _)| motive.len() > 40));
        assert!(ONBOARDING.iter().all(|(question, _, _, _)| question.ends_with('?')));
        assert!(ONBOARDING.iter().any(|(_, _, topic, _)| *topic == "boundaries"));
    }

    #[test]
    fn empty_sections_read_as_none() {
        assert_eq!(render(&[]), "- none");
        assert_eq!(render(&["a".to_owned()]), "- a");
    }
}
