FROM rust:1.98-alpine@sha256:a10e64dd139b7387337c7fbe8aca31b959b57b2fd4c8ae20a02cf1d6ea424dce AS builder

WORKDIR /app

RUN apk add --no-cache musl-dev

COPY Cargo.toml Cargo.lock ./
COPY src ./src
COPY migrations ./migrations
COPY personas ./personas
COPY prompts ./prompts
COPY evals ./evals
RUN cargo build --release --locked

FROM alpine:3.24@sha256:28bd5fe8b56d1bd048e5babf5b10710ebe0bae67db86916198a6eec434943f8b

RUN apk add --no-cache ca-certificates exiftool ffmpeg \
    && addgroup -S companion \
    && adduser -S -G companion companion \
    && mkdir -p /vault \
    && chown companion:companion /vault

COPY --from=builder /app/target/release/companion /usr/local/bin/companion

USER companion

CMD ["companion"]
