# Edith Architecture

## Design Goals

Edith is a native macOS control center whose background work stays small,
observable, and optional. Features own their timers and external processes,
shared state crosses explicit boundaries, and sensitive data remains on hosts
chosen by the user.

## Repository Layout

| Path | Responsibility |
| --- | --- |
| `Packages/Edith/Sources/Edith` | Main application lifecycle, navigation, windows, and feature screens. |
| `Packages/Edith/Sources/EdithHelper` | Always-on menu bar companion and system integrations. |
| `Packages/Edith/Sources/EdithKit` | Shared macOS models, services, defaults, IPC, paths, and update support. |
| `Packages/Edith/Sources/EdithCore` | Platform-neutral extension and capability models. |
| `Packages/Edith/Sources/EdithCLI` | Command tree, configuration, remote operations, and machine-readable output. |
| `Packages/Edith/Sources/EdithFiles` | Nested remote-file browser application. |
| `Packages/Edith/Sources/EdithLidAwakeHelper` | Privileged lid-awake helper executable. |
| `apps/companion` | Optional Rust service for private memory, retrieval, and media processing. |
| `apps/site` | Static product and policy website deployed through GitHub Pages. |
| `apps/promo-video` | Remotion source for release and announcement media. |
| `Resources` | Application property lists, launchd configuration, and packaged artwork. |

## Application Boundaries

The main app presents long-lived settings and fleet views. The menu bar
companion owns always-on integrations such as usage collection, clipboard
history, notifications, media controls, and machine monitoring. Both use shared
defaults and narrow IPC messages from EdithKit rather than reaching into each
other's UI state.

The `ed` and `edh` executables expose the same domain operations for scripts and
automation. Read commands provide JSON, logs use standard error, and exit codes
carry success or failure. Remote-machine operations execute through SSH using
the user's configured host and credentials.

## Companion Boundary

Companion is optional and deployed separately. The macOS app packages runtime
files, selects a host-specific Compose profile, and communicates with the API
through a loopback endpoint or SSH tunnel. PostgreSQL stores structured memory,
Redis coordinates transient work, and configured model services perform local
embedding, speech, vision, and reranking. A reasoning provider receives context
only when the user configures and selects it.

## Distribution

Xcode assembles the main application, menu bar companion, nested file browser,
CLI executables, privileged helper, resources, and Sparkle framework into one
bundle. Release automation signs the bundle, optionally notarizes it, creates a
DMG and signed appcast, publishes a GitHub Release, and mirrors the Homebrew
cask. GitHub Pages deploys `apps/site` independently.

## Trust Boundaries

The primary boundaries are user-approved macOS permissions, local files and
pasteboard contents, SSH hosts, the Companion network endpoint, provider
credentials, and the signed update channel. Changes that cross one of these
boundaries should document the data flow, minimize retained data, fail closed,
and include focused tests for authorization, parsing, and error handling.
