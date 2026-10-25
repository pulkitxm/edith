# Database extension delivery

Database is one downloadable marketplace extension. Its adapters share native
dependencies, so the package contains the supported database products together.
The small Edith app and bundled CLI ship without those drivers.

## Package contents

`Extensions/database` owns the interface and command routing. Its `DatabaseEngine`
package provides `DatabaseCore`, `DatabaseEngine`, and `DatabaseMCP`, including
models, persistence, security contracts, the actor executor, adapters, and MCP
command handling.

The extension engine runs inside Edith. `DatabaseWorkerClient` owns its
`DatabaseEngine` instance and dispatches typed commands directly. Each interface
presentation has its own client and page session. See [architecture](architecture.md)
for the command and adapter boundaries.

## Installation and compatibility

Use the Extensions page or `ed extensions install database`. Installation checks
the signed catalog, publisher signature, archive boundaries, checksum, host ABI,
architecture, and minimum macOS version before accepting the package.

Package versions live under the installation's `Extensions` directory. Database
state belongs to its separately owned data directory. Production and each
development worktree have separate roots.

Disabling Database cancels and drains its work. Swift code remains mapped until
the app quits. `ed extensions remove database` removes package files after their
leases are released and preserves saved user data. Installation and inspection
use the shared `ed extensions` commands.

## Release and verification

The Extensions workflow builds and verifies the package, publishes its immutable
archive and metadata, and includes it in the signed shared catalog. The app
release waits for a compatible catalog. Releases run through GitHub Actions.

Database tests cover typed commands, adapters, persistence, cancellation, and
presentation ownership. Marketplace tests cover installation verification,
rollback, removal, and retained data. Shareable query or interface evidence uses
synthetic databases and credentials.
