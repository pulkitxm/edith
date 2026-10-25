# Edith Architecture

## Design Goals

Edith is a native macOS control center built as a small host app plus optional
extensions. The host stays small and observable, each feature is an extension
that is downloaded only when the user wants it, shared state crosses explicit
boundaries, and sensitive data remains on hosts chosen by the user.

## Repository Layout

| Path | Responsibility |
| --- | --- |
| `Packages/EdithHost` | The host app: lifecycle, windows, navigation, Home, Notch, Extensions, Storage and Settings pages, permissions, updates, the `ed` command gateway and the extension loader. |
| `Packages/ExtensionMarketplace` | Signed catalog, package download and verification, installation state, leases and compatibility rules, shared by the host and the release tooling. |
| `Packages/ExtensionSupport` | Libraries that extensions link: commands, files, accounts, documents, archives and the shared UI kit. |
| `Packages/EdithStudio` | Studio's media engine: data-driven PDF, image, video, audio, document, web, archive and on-device AI tools, the job runner, and the PDF and image editing models. A standalone package so its suites build and run in seconds. |
| `Packages/EdithDocsWorker` | Bundled `ed` reference parsing, search and Docs Ask ranking. |
| `Extensions/<id>` | One extension: runtime, views, CLI commands, tests and native code. `Extensions/manifest.json` lists every extension with its version, roles, inputs and dependencies. |
| `skills` | Agent skills that the Plugins extension fetches from GitHub at runtime. |
| `apps/companion` | Optional Rust service for private memory, retrieval, and media processing. |
| `apps/music-player` | Rust Spotify playback engine used by the Music extension. |
| `apps/site` | Static product and policy website deployed through GitHub Pages. |
| `apps/promo-video` | Remotion source for release and announcement media. |
| `Resources` | Application property lists, entitlements, the `ed` launcher and packaged artwork. |
| `scripts` | Build, packaging, release and policy tooling. |

## Host and extensions

The host is the only app a user installs. It ships the shell, the marketplace,
Settings, Storage and the Home and Notch layout controls. Every other feature
is an extension. A downloaded extension is `<id>/package.json` plus one
`<role>.bundle` per role, loaded in process by the host. The only separate
processes are short-lived native task and CLI children, the virtual camera
system extension carrier, the lid-awake helper, and the `ed` launcher.

Extensions are built against the host contract in `Packages/ExtensionSupport`
and `Packages/ExtensionMarketplace`. `scripts/extension-host-abi.mjs` computes
the contract identifier from those sources, and the host refuses to load a
package built for a different one. An extension never links the host.

## Marketplace

Each extension is released as its own ZIP with JSON metadata and a detached
checksum. A signed catalog points to the immutable release assets. The host
verifies the publisher, package identity, archive boundaries, checksum, ABI,
architecture and minimum macOS version before loading code, and keeps the
previous version usable if a replacement fails. Release planning fingerprints
each extension's inputs, so a change rebuilds only the affected extensions and
their dependents. `docs/extension-marketplace.md` describes the user-facing
behavior.

## Studio

Studio is an extension whose engine lives in `Packages/EdithStudio` and has no
dependency on the rest of Edith. Every tool is a `StudioTool` value: an id, the
kinds of file it accepts, whether it runs per file or combines files, typed
options that the app renders as a form and `ed studio run --set key=value`
parses, the engines it needs, and a perform closure. `StudioRunner` validates
inputs and settings, runs each unit in a private staging folder, then moves
results next to the originals, into Downloads or into a chosen folder under a
name that never overwrites an existing file. Editors (image, PDF, video) and the
PDF compare view are tools with an editor style instead of a perform closure.
Workflows chain runnable tools into one tool.

PDF and image tools use PDFKit, Core Graphics, ImageIO, Core Image and Vision.
Video and audio tools use FFmpeg, and four PDF tools use qpdf; both are optional
engines found on the user's PATH and installed through the same Homebrew
provisioning as other tools. Summaries use the on-device Foundation Models, and
translation uses the macOS Translation languages the user has downloaded, so no
file leaves the Mac.

## Data

One data root, `~/Library/Application Support/Edith/`, holds the host's state and
each extension's owned data. Removing an extension retains its user data. A
development build keeps its data, caches and logs under `Edith Dev/<slot>`
instead, and can point the whole root elsewhere with the `EDITH_DATA_ROOT`
environment variable.

Caches live in `~/Library/Caches/Edith/`. They are regenerable and never synced.
Logs live in `~/Library/Logs/Edith/`.

## Command line

The `ed` executable exposes domain operations for scripts and automation. The
installer links it under the `ed` and `edith` names, and it connects to the
running Edith app. Read commands provide JSON, logs use standard error, and exit
codes carry success or failure. Extensions contribute their own command groups,
and the reference pages in `docs/cli` are bundled into `Packages/EdithDocsWorker`
by `scripts/generate-cli-docs-bundle.mjs`. Remote-machine operations execute
through SSH using the user's configured host and credentials.

## Companion Boundary

Companion is optional and deployed separately. The Companion extension packages
runtime files, selects a host-specific Compose profile, and communicates with the
API through a loopback endpoint or SSH tunnel. PostgreSQL stores structured
memory, Redis coordinates transient work, and configured model services perform
local embedding, speech, vision, and reranking. A reasoning provider receives
context only when the user configures and selects it.

## Distribution

`build.sh` runs `scripts/build-minimal-host.mjs` to build `Packages/EdithHost`
and `scripts/package-shipping-host.py` to assemble, sign and verify the bundle
with Sparkle and the `ed` launcher. `make verify-bundle` asserts the layout and
code-signing identifiers. Releases are published locally by
`scripts/release-local.sh`: it plans, builds, signs and publishes the changed
extension packages and the next signed catalog, then builds the app, creates the
DMG and signed appcast, publishes a GitHub Release, and mirrors the Homebrew
cask. GitHub Pages deploys `apps/site` independently.

## Trust Boundaries

The primary boundaries are user-approved macOS permissions, downloaded extension
packages and the signed catalog, local files and pasteboard contents, SSH hosts,
the Companion network endpoint, provider credentials, and the signed update
channel. Changes that cross one of these boundaries should document the data
flow, minimize retained data, fail closed, and include focused tests for
authorization, parsing, and error handling.
