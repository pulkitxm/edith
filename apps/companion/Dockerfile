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
