# Invoke

[CLI reference](../README.md)

Send an operation and a JSON payload to an already running extension worker:

```sh
ed invoke <id> <operation> --json '{"value":"synthetic"}'
printf '%s' '{"value":"synthetic"}' | ed invoke <id> <operation> --json -
ed invoke <id> <operation> --timeout 120 --json '{}'
```

The default payload is `{}`. The output is exactly the worker's JSON response. Operation names and payload schemas are defined by the downloaded extension. This gateway does not execute arbitrary paths or translate legacy command aliases.

Install and enable the extension first. An incompatible, disabled, stopped, stale, or unknown worker returns an error. Private `extension.*` host operations are rejected. If the worker or its selected version changes during the request, the result is rejected.

`--timeout` accepts 1 to 120 seconds; the default is 30 seconds. Provider hooks can pipe their JSON event to an extension-owned operation and receive the worker's provider-native JSON response. Closing the input without valid JSON, exceeding the payload limit, disconnecting, or reaching the timeout ends the request. See [conventions](../conventions.md) for limits and exit codes.
