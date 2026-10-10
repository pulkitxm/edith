# Music native bridge review

Music loads its signed native library inside its owned extension worker. The public gateway accepts typed JSON commands, never pointers or native handles.

The Swift owner validates service and display-name identities before loading the library. Start and forget pass explicit UTF-8 byte lengths. Rust rejects null, empty, oversized, embedded-null and invalid UTF-8 input before copying a bounded slice. Service identities are limited to 256 bytes, display names to 128 bytes and commands to 4,096 bytes. Command delivery uses a queue with 32 slots and rejects overflow.

The Swift owner keeps the library, callback receiver and native handle alive together. A lock serializes sends and stop. Stop takes the handle once, joins the native thread, releases the callback receiver and then unloads the library. Callback bytes stay alive for the synchronous callback, and Swift copies them before scheduling delivery. Swift rejects event payloads larger than 65,536 bytes. The callback does not call native stop while Rust holds its event-sink lock. Rust's opaque box is borrowed only for send and consumed once by stop.

These C ABI operations require unsafe pointer access. The security gate permits only `rust.lang.security.unsafe-usage.unsafe-usage` findings in `Extensions/music/Native/src/lib.rs` when its full SHA-256 matches the reviewed source in `scripts/check-semgrep.py`. Any source change requires another review. All other rules on this file, the same rule on other files, fatal scan errors and malformed reports remain blocking. Parser warnings on the reviewed Rust source also block approval. The four existing rule packs still scan the entire repository. Existing nonfatal parser warnings elsewhere remain visible in the scan summary and retain Semgrep's normal exit behavior.

Verification uses synthetic byte buffers and a synthetic native library. Rust tests exercise exact non-terminated lengths, invalid bytes, queue overflow and handle shutdown. Swift tests exercise UTF-8 lengths, invalid identities, callback ownership and idempotent stop. These tests do not access provider accounts or production configuration.
