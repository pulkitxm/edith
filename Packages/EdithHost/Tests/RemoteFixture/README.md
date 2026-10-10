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
