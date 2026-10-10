# Conventions

[CLI reference](./README.md)

Commands emit one JSON document on stdout. `--json` is optional for marketplace commands because their results are always JSON. `--help` prints usage text. `--version` emits an object containing `version`.

Failures emit a JSON object containing `error` and `exitCode` on stderr. Failed commands leave stdout empty.

| Exit code | Meaning |
| --- | --- |
| 0 | Success |
| 1 | A marketplace or worker operation failed or was rejected |
| 2 | Unknown command, invalid arguments, or invalid JSON |
| 3 | This Edith installation has no authenticated running app session |
| 4 | The request timed out and was cancelled |

Invocation payloads are limited to 512 KiB. Read stdin with `--json -`; stdin must finish within five seconds. Invocation timeouts range from 1 to 120 seconds, with a default of 30 seconds. Results are limited to 8 MiB. The app admits at most eight command connections. An incomplete request expires after five seconds.

The gateway authenticates both processes using the kernel peer identity, the same user ID, the exact app executable path, and the current executable code hash. Each app installation owns a private socket and an exclusive lease. Caller-supplied paths, process IDs, executable names, and private host operations cannot grant access.

The app must already be running. `invoke` requires a compatible installed worker that is active in the current app session. It does not enable the extension, reuse an old session, or start a helper. Downloads and worker operations run asynchronously so the app remains responsive.

Closing the CLI connection cancels the app's request. An invocation timeout cancels the worker request through its existing command protocol. Installed files and user data follow the same ownership and recovery rules as the marketplace UI. Disable stops the worker; remove deletes installed packages while retaining extension preferences and user data.
