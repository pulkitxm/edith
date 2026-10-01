# Database pack delivery

The database drivers leave the Edith executable. One downloadable pack contains every database product. The drivers share SwiftNIO and BoringSSL, so splitting the pack per product would duplicate that code. The app, the `ed` CLI, and the database MCP server keep a small client library and talk to a separate broker process.

The original product stack (foundation through hardening) has already landed. This file is the delivery plan for the pack.

## Modules

`EdithDatabase` is the client. The app, CLI, and `EdithDatabaseMCP` link it. It holds:

- Models, command contracts, and the request and result types those commands carry
- The broker client, socket transport, protocol frames, health probe, and executable launcher
- Saved-connection persistence and Keychain secret storage
- Confirmation and continuation types the interface and CLI encode

It depends on `EdithCore` and GRDB for the metadata store. It does not depend on SwiftUI, ArgumentParser, `EdithKit`, or the driver libraries.

`EdithDatabaseDrivers` holds the adapters, the executor, the session pool, and the broker runtime and process. The client does not depend on it. After the executable split, the main app does not link it either.

`EdithDatabaseMCP` stays with the client. It sends broker commands and does not link drivers.

```text
Database views       ed database commands       MCP tools
       |                      |                     |
       +----------- EdithDatabase client ----------+
                              |
                    Unix socket, signed peer
                              |
                         edith-database
                              |
                   executor and adapters
```

## Executable

`edith-database` is a separate executable. It runs the broker process and links `EdithDatabaseDrivers`. The app and CLI launch that binary instead of re-entering the main executable with `EDITH_DATABASE_BROKER`.

It is signed with the same team as Edith, with the hardened runtime, and notarized with the app. The code identifier is `com.pulkit.edith.database`. A development build uses `com.pulkit.edith.dev.<slot>.database`.

## Signature requirement

The launcher and the peer authenticator require a designated requirement of that identifier plus the Edith team identifier (`certificate leaf[subject.OU]`). They no longer require the broker to be the same binary as the app. A pack that fails the checksum or the signature is not installed and is not launched.

## Install and version

The pack for the running app version is one zip on the matching GitHub release, with a SHA-256 checksum beside it.

The app offers the download when the Database extension is enabled and the pack is missing. `ed database` does the same when a command needs the broker and the pack is missing. Progress is shown in the interface. The CLI commands are:

- `ed database pack install`
- `ed database pack status`
- `ed database pack remove`

Each accepts `--json` and documents its flags in `--help`.

Install location, using the same data root as the rest of the app:

- Production: `~/Library/Application Support/Edith/DatabasePack`
- Development: `~/Library/Application Support/Edith Dev/<slot>/DatabasePack`

The directory is `DatabasePack`, not `database`, so it does not collide with the broker's data directory on a case-insensitive volume.

The installed pack records the app version it was built for. A pack whose version differs from the running app is invalid. The next launch or `ed database` command replaces it. Removing the pack deletes that directory.

Development builds do not download. `build.sh` builds `edith-database` and installs it into the slot.

## Release

The existing release workflow (`.github/workflows/ci.yml` and `scripts/release-local.sh`) builds the pack with the app, signs it with the same identity and hardened runtime, notarizes it, and uploads a versioned zip plus checksum as release assets. The pack version matches the app version. A dry run of the local release script packages the asset without publishing.

## Pull request stack

Each layer stays under about 2,000 changed lines. Later layers rebase onto the previous branch.

| Order | Branch | Scope |
| ---: | --- | --- |
| 1 | `database-pack-modules` | Split `EdithDatabase` and `EdithDatabaseDrivers` with no behavior change. The app still links both, and the broker still starts inside `EdithMain`. |
| 2 | `database-pack-executable` | `edith-database` executable, `build.sh` slot install, launcher and peer requirement relaxed to team plus identifier. The app stops linking the drivers. |
| 3 | `database-pack-install` | Download, checksum, and signature verification, install and removal, version invalidation, CLI commands, and the extension download flow. |
| 4 | `database-pack-release` | The release workflow publishes the pack zip and checksum. |

## Tests

Existing `EdithDatabaseTests` stay green. Suites that need driver internals move to `EdithDatabaseDriversTests` or import that module. New tests cover checksum mismatch, signature rejection, version mismatch, install, remove, and CLI `--json` output.

## Gates

A layer is pushed only when its focused tests, Swift format, and comment check pass. The release layer also dry-runs the pack packaging when the workflow supports it, and does not cut a release. Evidence is one comment on the finished stack: sanitized `ed database pack status --json`, a query against a synthetic SQLite file, and the Edith executable size before and after.
