# Edith Architecture

## Design Goals

Edith is a native macOS control center whose background work stays small,
observable, and optional. One process owns collection, features declare where
they run rather than discovering it, shared state crosses explicit boundaries,
and sensitive data remains on hosts chosen by the user.

## Repository Layout

| Path | Responsibility |
| --- | --- |
| `Packages/Edith/Sources/Edith` | Main application lifecycle, navigation, windows, and feature screens. |
| `Packages/Edith/Sources/EdithAgent` | Background agent internals: XPC hub, job scheduler, SQLite store, collectors. |
| `Packages/Edith/Sources/edithd` | Headless background agent executable. |
| `Packages/Edith/Sources/EdithHelper` | Always-on menu bar companion and system integrations. |
| `Packages/Edith/Sources/EdithKit` | Shared macOS models, services, defaults, agent protocol, paths, and update support. |
| `Packages/Edith/Sources/EdithCore` | Platform-neutral suite, ability, and capability models. |
| `Packages/Edith/Sources/EdithCLI` | Command tree, configuration, remote operations, and machine-readable output. |
| `Packages/Edith/Sources/EdithLidAwakeHelper` | Privileged lid-awake helper executable. |
| `apps/companion` | Optional Rust service for private memory, retrieval, and media processing. |
| `apps/site` | Static product and policy website deployed through GitHub Pages. |
| `apps/promo-video` | Remotion source for release and announcement media. |
| `Resources` | Application property lists, launchd configuration, and packaged artwork. |

## Processes

Four processes, each with one reason to exist.

`edithd` is a LaunchAgent, not a daemon: it needs the user's home, Keychain,
SSH and iCloud container. `Resources/com.pulkit.edith.agent.plist` ships in
`Contents/Library/LaunchAgents`, the app registers it with
`SMAppService.agent(plistName:)`, and launchd starts it on demand through its
Mach service and keeps it alive while the Login Items entry is enabled. It runs
a Foundation run loop with an `NSXPCListener` and no AppKit UI. It owns
collection and long jobs.

Edith Bar is the login item helper. It keeps only what needs a WindowServer
session or a TCC grant: the clipboard tap, keystroke highlight, focus dim, the
presenter, the microphone, the notch, playback and EventKit. It publishes into
the agent rather than owning shared state.

The Edith window, the `ed` executable and `ed database mcp` are thin XPC
clients of the same operation catalog.

The privileged lid-awake helper is unchanged: a `pmset`-only LaunchDaemon.

**Placement rule.** A job lives in the agent unless it needs a WindowServer
session or a TCC grant. The agent never asks for a permission.

## The agent

`JobScheduler` is an actor. Each job declares an id, a trigger (timer, file
system, subscription, queue), an ambient cadence that runs with no window open,
a live cadence that applies while an XPC subscriber holds its topic, and a
power policy. Subscribing to a topic raises the cadence; dropping the last
subscriber lowers it. A job whose ability is off reports `disabled` rather than
running.

The XPC hub listens on `com.pulkit.edith.agent`. Peers are authenticated with
`NSXPCListener.setConnectionCodeSigningRequirement`, built from the agent's own
team identifier and falling back to identity alone for ad-hoc builds. Every
connection handshakes a protocol version first and a mismatched peer is refused
with a relaunch hint.

`perform(operation:payload:)` is the only RPC verb. Operations are
`UserOperationID` values from `UserOperationCatalog`, and the agent registers a
handler for each id it declares in `AgentOperationCatalog`. Clients refuse an
unserved operation before it reaches the wire.

One GRDB SQLite database, `edith.sqlite`, in WAL mode, with the agent as sole
writer. UI processes never open it; they receive typed Codable snapshots and
topic pushes over XPC. Migrations are forward-only and numbered through
`DatabaseMigrator`; the file is copied to `edith.sqlite.pre-<build>` before a
migration runs, copies older than thirty days are pruned, and a store written
by a newer schema is refused rather than downgraded.

## Suites and abilities

The registry has two levels. A **suite** is what you enable. An **ability** is a
toggle inside it that declares its host (`agent`, `bar`, `window`), its
permissions, its tools and the abilities it requires.

Core is always on: Home, Fleet (this Mac plus SSH machines, files, Docker,
terminal), Extensions, Settings, the agent, `ed` and MCP. Six suites hold the
rest: Agents, Maintenance, System, Desk, Media, Data.

Enablement is layered. `isSelected` reads the raw defaults key, `isEnabled`
also requires the suite and every declared requirement. Enabling an ability
turns its suite on and pulls in what it requires; disabling one clears its
dependents. Turning a suite off remembers which abilities were on so turning it
back on restores them.

The sidebar and every suite landing page are generated from that table. Adding
an ability is a registry entry, not a new switch statement.

## Data

One data root, `~/Library/Application Support/Edith/`: the store, `machines/`,
`clipboard/`, `seo/`, `settings.json` and music unless another folder is
chosen. `DataRoot` names each location once. A development build points the
whole root elsewhere with the `EDITH_DATA_ROOT` environment variable; there is
no setting for it, so it cannot travel in a backup.

Caches live in `~/Library/Caches/Edith/`, including `Runtime/` for SSH
ControlMaster sockets. They are regenerable and never synced. Logs live in
`~/Library/Logs/Edith/` and are pruned after seven days.

`BackupCatalog` states what leaves this Mac: nine data classes, each with
whether it always syncs, opts in or never leaves, how it merges on restore, and
how long it is kept. Machines and database connections sync without their
secrets, which stay in the Keychain and are re-entered per Mac. The agent runs
one backup scheduler: change-driven with a sixty second debounce plus a daily
JSONL snapshot per synced table.

## Application Boundaries

The main app presents long-lived settings and fleet views. The menu bar
companion owns integrations that need a session or a grant. Both read shared
defaults and subscribe to the agent rather than reaching into each other's UI
state.

The `ed` executable exposes domain operations for scripts and automation. The
installer links it under the `ed` and `edith` names. Read commands provide
JSON, logs use standard error, and exit codes carry success or failure.
Remote-machine operations execute through SSH using the user's configured host
and credentials.

### User operation parity

Actionable UI behavior enters `UserOperationCatalog` as a
`RegisteredUserOperation`. Each registration owns one shared operation
descriptor and declares either its UI placements with parseable example
arguments, or a specific reason it is command-line only. The catalog derives
the UI action registry from those registrations, so the UI inventory, operation
identity and CLI route cannot drift into separate sources of truth.

`CLIParityTests` resolves every registered route through the argument parser and
the completion tree. It also keeps the remaining unshared UI inventory visible
until an exact operation, UI surface and example invocation move behind a typed
placement. Focus, scrolling, folding, local filtering, modal visibility and
mouse capture are recorded separately as presentation-only state and do not
need CLI commands.

### Command tree

`CommandTree` derives its structure from `EdRoot`'s `CommandConfiguration`:
names, abstracts, aliases, nesting and `shouldDisplay`. Only what the argument
parser cannot express stays declarative, keyed by command path: option value
kinds, positional kinds, destructive policy and passthrough rules. A test keeps
that table free of stale keys.

## Companion Boundary

Companion is optional and deployed separately. The macOS app packages runtime
files, selects a host-specific Compose profile, and communicates with the API
through a loopback endpoint or SSH tunnel. The agent owns the forward while the
Memory ability is on, so `ed companion` and the Memory MCP tools work with the
window closed. PostgreSQL stores structured memory, Redis coordinates transient
work, and configured model services perform local embedding, speech, vision,
and reranking. A reasoning provider receives context only when the user
configures and selects it.

## Distribution

Xcode assembles the main application, menu bar companion, CLI executable and
alias, background agent, privileged helper, resources, and Sparkle framework
into one bundle. `make verify-bundle` asserts the layout, including the agent
binary, its LaunchAgent plist and its code-signing identifier. Release
automation signs the bundle, optionally notarizes it, creates a DMG and signed
appcast, publishes a GitHub Release, and mirrors the Homebrew cask. GitHub
Pages deploys `apps/site` independently.

Surviving an update: on first launch of a new build the app compares its
version to the `installedBuild` stamp, re-registers the agent and restarts it,
because replacing the binary leaves the old agent running. The agent then
copies the store and runs migrations.

## Trust Boundaries

The primary boundaries are user-approved macOS permissions, the agent's XPC
service, local files and pasteboard contents, SSH hosts, the Companion network
endpoint, provider credentials, and the signed update channel. Changes that
cross one of these boundaries should document the data flow, minimize retained
data, fail closed, and include focused tests for authorization, parsing, and
error handling.
