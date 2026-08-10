FROM rust:1.97-slim AS builder

WORKDIR /app

COPY Cargo.toml Cargo.lock ./
COPY src ./src
COPY migrations ./migrations
COPY personas ./personas
COPY prompts ./prompts
COPY evals ./evals
RUN cargo build --release --locked

FROM debian:trixie-slim

RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates ffmpeg libimage-exiftool-perl && rm -rf /var/lib/apt/lists/*

COPY --from=builder /app/target/release/companion /usr/local/bin/companion

CMD ["companion"]
