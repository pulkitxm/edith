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

RUN apk add --no-cache ca-certificates exiftool ffmpeg

COPY --from=builder /app/target/release/companion /usr/local/bin/companion

CMD ["companion"]
