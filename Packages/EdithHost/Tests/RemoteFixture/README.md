# Signed remote scene fixture

This fixture runs a synthetic owned engine through the real HostWorker, peer
server, remote session manager, authenticated XPC bridge, scoped UI SDK and
public ExtensionKit scene. It verifies remote engine reads, cancellation,
last-presentation process exit, disable, fresh process generations and package
lease release. It does not exercise any shipping feature engine or user data.

Build EdithHost in release mode with `EDITH_CLI_FIXTURE` and the normal compiler
plugin path. Prepare an isolated directory under
`~/Applications/Edith Remote Fixture <unique suffix>`:

```sh
bun scripts/prepare-host-remote-fixture.mjs "$fixture_dir" "$frozen_host" "$synthetic_identifier"
bun scripts/test-host-remote-ui.mjs launch "$fixture_dir"
```

The identifier must start with `com.pulkit.edith.tests.remote-`. Preparation
uses the single configured local development signing identity without printing
it. The host, carrier and sandboxed extension use the same compiled executable.
All role resources are synthetic and remain inside the extension's sealed bundle.

For background verification, run `bun scripts/test-host-remote-ui.mjs register-public "$fixture_dir"`.
This fixture creates an unshown offscreen window and never orders, focuses or
activates it. The host runs as a direct child process; its sealed carrier checks
in through public NSWorkspace without activating or opening a window. The
`register` operation separately exercises the fixture-only direct carrier stub.
An unapproved fixture reports approval required without opening the system
browser. An approved fixture checks scene activation, the authenticated read-only
control connection, verified UI process exit and package lease release while the
engine remains disabled. The result is written to `result-registration.json`.

Preparation accepts a selected version followed by retained versions. Normal
background verification must select the current registration without probing
retained identities. `register-stale` separately forces a retained registration
and requires path rejection before native loading, verified rejected-process
exit and released leases. `register-cleanup` verifies closing, disabling and
expiring selected scenes before connection, with no UI or engine process start.
Each operation runs in a fresh host process.

If launch reports `publicApprovalRequired`, enable this fixture's ExtensionWorker
in its displayed public macOS extension browser, then run:

```sh
bun scripts/test-host-remote-ui.mjs approved "$fixture_dir"
```

Click **Read owned record** in the embedded scene and verify the count increases.
Click **Hold owned request**, then immediately run:

```sh
bun scripts/test-host-remote-ui.mjs verify "$fixture_dir"
```

Verification exits the fixture after all lifecycle assertions pass and writes
`result.json`. Public approval and button interaction require a GUI session.
The fixture flags and source bodies are excluded from production builds.

## Shipping original-view background smoke

Worker lifecycle verification and managed view verification are separate. The
worker harness reports `engineLifecycleValidated: true`, `nativeWindow: false`
and `managedNativeViewValidated: false`. Engine command, update, cancellation,
disable and package removal checks do not prove an embedded view.

Build the fixture host with `EDITH_CLI_FIXTURE` and prepare a selected shipping
extension using `prepare-managed-shipping-fixture.mjs`. Preparation builds its
actual scoped release roles, uses the configured signing identity, preserves
current package metadata and installs the selected version into a private test
store. It uses the same frozen executable in the host and carrier. No synthetic
replacement UI role or direct carrier stub is used.

```sh
bun scripts/prepare-managed-shipping-fixture.mjs calendar "$fixture_dir" "$frozen_host" "$synthetic_identifier" "$fixture_executable"
bun scripts/test-managed-shipping-ui.mjs "$fixture_dir"
```

The selected provider must first support a validated synthetic backend bound to
this fixture host, canonical package and private data root. The runner passes
`EDITH_EXTENSION_FIXTURE_HOME=$fixture_dir/synthetic-data`. A directory or an
environment variable alone does not make a feature engine safe: verify its
provider-owned admission and injected services before running it. Do not use
production preferences, caches, permissions, network services or feature data.

This background runner embeds the original selected main scene in a window
that is never shown, ordered, focused or activated. It requires real public
carrier registration and authenticated control readiness, two fresh UI process
generations, last-close exit, engine disable, empty owned process state and
released package leases. Public approval required is a failed smoke, never
native-view success. It does not open an approval browser or a standalone
extension main-page window. The result is `result-managed-shipping.json`.

Each of the 39 final packages still needs its selected original-role smoke with
provider-owned safe fixtures after the final source and frozen host settle.
Passing worker lifecycle checks or the synthetic `sample` registration fixture
is insufficient. No visible layout, keyboard interaction or OS feature actions
are verified by this background smoke.
