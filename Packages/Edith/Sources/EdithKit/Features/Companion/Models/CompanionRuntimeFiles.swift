import Foundation

public enum CompanionRuntimeFiles {
    public static let composeBase = #"""
        services:
          postgres:
            image: pgvector/pgvector:pg18
            restart: unless-stopped
            environment:
              POSTGRES_DB: companion
              POSTGRES_USER: companion
              POSTGRES_PASSWORD: ${COMPANION_PG_PASSWORD:-companion-dev}
            ports:
              - "127.0.0.1:${COMPANION_PG_PORT:-5432}:5432"
            volumes:
              - companion-pg:/var/lib/postgresql
            healthcheck:
              test: ["CMD-SHELL", "pg_isready -U companion -d companion"]
              interval: 5s
              timeout: 5s
              retries: 10
          redis:
            image: redis:8-alpine
            restart: unless-stopped
            ports:
              - "127.0.0.1:${COMPANION_REDIS_PORT:-6379}:6379"
            healthcheck:
              test: ["CMD", "redis-cli", "ping"]
              interval: 5s
              timeout: 5s
              retries: 10
          ollama:
            image: ollama/ollama:latest
            restart: unless-stopped
            volumes:
              - companion-ollama:/root/.ollama
          whisper:
            image: ghcr.io/ggml-org/whisper.cpp:main
            restart: unless-stopped
            entrypoint: ["/bin/sh", "-c"]
            command:
              - test -f /models/${COMPANION_STT_MODEL:-ggml-base.bin} || /app/models/download-ggml-model.sh ${COMPANION_STT_MODEL_NAME:-base} /models; exec /app/build/bin/whisper-server -m /models/${COMPANION_STT_MODEL:-ggml-base.bin} --host 0.0.0.0 --port 8080
            volumes:
              - companion-whisper:/models
          api:
            build: .
            restart: unless-stopped
            depends_on:
              postgres:
                condition: service_healthy
              redis:
                condition: service_healthy
              ollama:
                condition: service_started
              whisper:
                condition: service_started
            environment:
              DATABASE_URL: postgres://companion:${COMPANION_PG_PASSWORD:-companion-dev}@postgres:5432/companion
              REDIS_URL: redis://redis:6379
              VAULT_DIR: /vault
              EMBED_URL: http://ollama:11434
              EMBED_MODEL: ${COMPANION_EMBED_MODEL:-qwen3-embedding:0.6b}
              STT_URL: http://whisper:8080
              STT_QUALITY_URL: ${COMPANION_STT_QUALITY_URL:-}
              VLM_URL: ${COMPANION_VLM_URL:-http://ollama:11434}
              VLM_MODEL: ${COMPANION_VLM_MODEL:-qwen3-vl:8b}
              RERANK_URL: ${COMPANION_RERANK_URL:-}
              RERANK_MODEL: ${COMPANION_RERANK_MODEL:-qwen3-reranker:0.6b}
              GROUNDING_URL: ${COMPANION_GROUNDING_URL:-}
              PERSONA_DIR: ${COMPANION_PERSONA_DIR:-}
              NOTION_TOKEN: ${NOTION_TOKEN:-}
              GITHUB_TOKEN: ${GITHUB_TOKEN:-}
              ANTHROPIC_API_KEY: ${ANTHROPIC_API_KEY:-}
              REASON_PROVIDER: ${COMPANION_REASON_PROVIDER:-}
              REASON_URL: ${COMPANION_REASON_URL:-}
              REASON_MODEL: ${COMPANION_REASON_MODEL:-}
              COMPANION_REFLECT_AT: ${COMPANION_REFLECT_AT:-02:00}
              COMPANION_SCHEDULE_EVERY_SECONDS: ${COMPANION_SCHEDULE_EVERY_SECONDS:-}
            ports:
              - "${COMPANION_API_BIND:-127.0.0.1}:${COMPANION_API_PORT:-4820}:4820"
            volumes:
              - companion-vault:/vault

        volumes:
          companion-pg:
          companion-vault:
          companion-ollama:
          companion-whisper:

        """#

    public static let composeCpu = #"""
        services:
          whisper:
            command:
              - test -f /models/${COMPANION_STT_MODEL:-ggml-base.bin} || /app/models/download-ggml-model.sh ${COMPANION_STT_MODEL_NAME:-base} /models; exec /app/build/bin/whisper-server -m /models/${COMPANION_STT_MODEL:-ggml-base.bin} --host 0.0.0.0 --port 8080 --threads ${COMPANION_STT_THREADS:-4}
          api:
            environment:
              EMBED_MODEL: ${COMPANION_EMBED_MODEL:-qwen3-embedding:0.6b}
              VLM_MODEL: ${COMPANION_VLM_MODEL:-qwen3-vl:2b}
              RERANK_URL: ${COMPANION_RERANK_URL:-}

        """#

    public static let composeMac = #"""
        services:
          ollama:
            profiles: ["never"]
          whisper:
            profiles: ["never"]
          api:
            depends_on:
              postgres:
                condition: service_healthy
              redis:
                condition: service_healthy
            environment:
              EMBED_URL: ${COMPANION_EMBED_URL:-http://host.docker.internal:11434}
              VLM_URL: ${COMPANION_VLM_URL:-http://host.docker.internal:11434}
              STT_URL: ${COMPANION_STT_URL:-http://host.docker.internal:8081}
              STT_QUALITY_URL: ${COMPANION_STT_QUALITY_URL:-http://host.docker.internal:8082}
              RERANK_URL: ${COMPANION_RERANK_URL:-}
            extra_hosts:
              - "host.docker.internal:host-gateway"

        """#

    public static let dockerfile = #"""
        FROM rust:1.97-alpine AS builder

        WORKDIR /app

        RUN apk add --no-cache musl-dev

        COPY Cargo.toml Cargo.lock ./
        COPY src ./src
        COPY migrations ./migrations
        COPY personas ./personas
        COPY prompts ./prompts
        COPY evals ./evals
        RUN cargo build --release --locked

        FROM alpine:3.22

        RUN apk add --no-cache ca-certificates exiftool ffmpeg \
            && addgroup -S companion \
            && adduser -S -G companion companion \
            && mkdir -p /vault \
            && chown companion:companion /vault

        COPY --from=builder /app/target/release/companion /usr/local/bin/companion

        USER companion

        CMD ["companion"]

        """#

    public static let all: [(name: String, content: String)] = [
        ("compose.yaml", composeBase),
        ("compose.cpu.yaml", composeCpu),
        ("compose.mac.yaml", composeMac),
        ("Dockerfile", dockerfile),
    ]
}
