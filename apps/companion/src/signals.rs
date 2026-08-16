use sqlx::PgPool;
use uuid::Uuid;

use crate::baseline::episode_context_bucket;
use crate::stt::TranscriptSegment;

const EXTRACTOR: &str = "segments-v1";

pub struct Signal {
    pub t_start_s: f32,
    pub t_end_s: f32,
    pub kind: &'static str,
    pub value: f32,
}

pub fn signals_from_segments(segments: &[TranscriptSegment], duration: Option<f32>) -> Vec<Signal> {
    let mut signals = Vec::new();
    let mut spoken = 0.0f32;

    for pair in segments.windows(2) {
        let gap = pair[1].start - pair[0].end;
        if gap >= 1.0 {
            signals.push(Signal {
                t_start_s: pair[0].end,
                t_end_s: pair[1].start,
                kind: "pause_s",
                value: gap,
            });
        }
    }

    for segment in segments {
        let seconds = segment.end - segment.start;
        spoken += seconds.max(0.0);
        let words = segment.text.split_whitespace().count() as f32;
        if seconds >= 2.0 && words >= 3.0 {
            signals.push(Signal {
                t_start_s: segment.start,
                t_end_s: segment.end,
                kind: "wpm",
                value: words / seconds * 60.0,
            });
        }
    }

    let total = duration
        .filter(|value| *value > 0.0)
        .or_else(|| segments.last().map(|segment| segment.end))
        .unwrap_or(0.0);
    if total > 0.0 && !segments.is_empty() {
        signals.push(Signal {
            t_start_s: 0.0,
            t_end_s: total,
            kind: "speech_ratio",
            value: (spoken / total).clamp(0.0, 1.0),
        });
    }

    signals
}

pub async fn store_signals(
    pool: &PgPool,
    episode_id: Uuid,
    signals: &[Signal],
) -> Result<(), sqlx::Error> {
    let bucket = episode_context_bucket(pool, episode_id).await;
    for signal in signals {
        sqlx::query(
            "INSERT INTO signals (episode_id, t_start_s, t_end_s, kind, value, extractor, context_bucket) VALUES ($1, $2, $3, $4, $5, $6, $7)",
        )
        .bind(episode_id)
        .bind(signal.t_start_s)
        .bind(signal.t_end_s)
        .bind(signal.kind)
        .bind(signal.value)
        .bind(EXTRACTOR)
        .bind(&bucket)
        .execute(pool)
        .await?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::signals_from_segments;
    use crate::stt::TranscriptSegment;

    fn segment(start: f32, end: f32, text: &str) -> TranscriptSegment {
        TranscriptSegment {
            start,
            end,
            text: text.to_owned(),
        }
    }

    #[test]
    fn long_gaps_become_pauses_and_rates_compute() {
        let segments = vec![
            segment(0.0, 4.0, "one two three four five six seven eight"),
            segment(6.5, 10.5, "nine ten eleven twelve"),
        ];
        let signals = signals_from_segments(&segments, Some(11.0));
        let pause = signals
            .iter()
            .find(|signal| signal.kind == "pause_s")
            .unwrap();
        assert!((pause.value - 2.5).abs() < 0.01);
        let rates = signals.iter().filter(|signal| signal.kind == "wpm").count();
        assert_eq!(rates, 2);
        let ratio = signals
            .iter()
            .find(|signal| signal.kind == "speech_ratio")
            .unwrap();
        assert!((ratio.value - 8.0 / 11.0).abs() < 0.01);
    }

    #[test]
    fn short_gaps_and_tiny_segments_are_ignored() {
        let segments = vec![segment(0.0, 1.0, "hi"), segment(1.5, 2.4, "there")];
        let signals = signals_from_segments(&segments, Some(2.4));
        assert!(signals.iter().all(|signal| signal.kind != "pause_s"));
        assert!(signals.iter().all(|signal| signal.kind != "wpm"));
    }
}
