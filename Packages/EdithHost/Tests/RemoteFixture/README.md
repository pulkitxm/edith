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
