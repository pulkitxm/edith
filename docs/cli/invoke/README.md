# `ed invoke`

[CLI reference](../README.md)

Send an operation and a JSON payload to an already running extension worker:

```sh
ed invoke <id> <operation> --json '{"value":"synthetic"}'
printf '%s' '{"value":"synthetic"}' | ed invoke <id> <operation> --json -
ed invoke <id> <operation> --timeout 120 --json '{}'
ed invoke <id> <operation> --json - --raw
```

The default payload is `{}`. The output is exactly the worker's JSON response. `--raw` decodes a JSON string response and prints its UTF-8 text with a trailing newline. It rejects other response types. Use it for a worker-owned plain-text statusline. Operation names and payload schemas are defined by the downloaded extension. This gateway does not execute arbitrary paths or translate legacy command aliases.

Install and enable the extension first. An incompatible, disabled, stopped, stale, or unknown worker returns an error. Private `extension.*` host operations are rejected. If the worker or its selected version changes during the request, the result is rejected.

`--timeout` accepts 1 to 120 seconds; the default is 30 seconds. Provider hooks can pipe their JSON event to an extension-owned operation and receive the worker's provider-native JSON response. Closing the input without valid JSON, exceeding the payload limit, disconnecting, or reaching the timeout ends the request. See [conventions](../conventions.md) for limits and exit codes.

## Usage status lines

For Usage, enable the extension, open its settings, and connect the Claude Code status line explicitly. This preserves a previous status-line command and restores it when Usage stops. You can inspect or manage the same owned connection through the active worker:

```sh
ed invoke usage usage.statusline.install --json '{}'
ed invoke usage usage.statusline.status --json '{}'
ed invoke usage usage.statusline.remove --json '{}'
ed invoke usage usage.statusline.hook --json - --raw < synthetic-status.json
```

The installed provider hook pipes its JSON input to `usage.statusline.hook`. It returns a JSON string, and `--raw` prints the provider's plain-text line. Input is limited to 512 KiB and must finish within five seconds. A document without usable limits returns an empty line. Disabling Usage restores the previous command or removes its exact owned hook; reenabling resumes only the saved opt-in connection. Foreign edits remain untouched. Explicitly disconnecting clears the connection intent.
