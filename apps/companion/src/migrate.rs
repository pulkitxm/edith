use std::collections::HashSet;

use sqlx::PgPool;

const MIGRATIONS: &[(&str, &str)] = &[
    (
        "0001_foundation",
        include_str!("../migrations/0001_foundation.sql"),
    ),
    ("0002_chunks", include_str!("../migrations/0002_chunks.sql")),
    (
        "0003_observation_dedupe",
        include_str!("../migrations/0003_observation_dedupe.sql"),
    ),
    (
        "0004_beliefs",
        include_str!("../migrations/0004_beliefs.sql"),
    ),
    (
        "0005_corroborations",
        include_str!("../migrations/0005_corroborations.sql"),
    ),
    (
        "0006_nightly_runs",
        include_str!("../migrations/0006_nightly_runs.sql"),
    ),
    ("0007_turns", include_str!("../migrations/0007_turns.sql")),
    (
        "0008_belief_embeddings",
        include_str!("../migrations/0008_belief_embeddings.sql"),
    ),
    (
        "0009_signals",
        include_str!("../migrations/0009_signals.sql"),
    ),
    (
        "0010_chat_settings",
        include_str!("../migrations/0010_chat_settings.sql"),
    ),
    ("0011_brain", include_str!("../migrations/0011_brain.sql")),
    (
        "0012_bilingual_index",
        include_str!("../migrations/0012_bilingual_index.sql"),
    ),
];

pub async fn run_migrations(pool: &PgPool) -> Result<(), sqlx::Error> {
    sqlx::query(
        "CREATE TABLE IF NOT EXISTS schema_migrations (version text PRIMARY KEY, applied_at timestamptz NOT NULL DEFAULT now())",
    )
    .execute(pool)
    .await?;

    let applied = sqlx::query_scalar::<_, String>("SELECT version FROM schema_migrations")
        .fetch_all(pool)
        .await?
        .into_iter()
        .collect::<HashSet<_>>();

    for &(version, migration_sql) in MIGRATIONS {
        if applied.contains(version) {
            continue;
        }

        let mut transaction = pool.begin().await?;
        sqlx::raw_sql(migration_sql)
            .execute(&mut *transaction)
            .await?;
        sqlx::query("INSERT INTO schema_migrations (version) VALUES ($1)")
            .bind(version)
            .execute(&mut *transaction)
            .await?;
        transaction.commit().await?;
    }

    Ok(())
}

pub const fn migration_count() -> usize {
    MIGRATIONS.len()
}
