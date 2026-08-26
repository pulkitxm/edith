# `ed machines docker inspect`

Reads the same structured container details as the app's Inspect tab.

```
ed machines docker inspect <machine> <container> [--json]
```

## Arguments

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `<machine>` | machine name, ssh alias, id, or unambiguous prefix | required | Which machine to ask. |
| `<container>` | container name or id | required | Which container to inspect. |

## Options

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--json` | flag | off | Emit stable JSON instead of the field table. |
| `--help`, `-h` | flag | off | Print help and exit 0. |

Plain output is a two-column table covering image, command, creation time,
restart policy, environment, mounts, networks and labels.

## `--json` shape

```json
{
  "command": "serve",
  "created": "2026-08-23T10:00:00Z",
  "environment": ["PORT=8080"],
  "image": "example/api:latest",
  "labels": {"service": "api"},
  "mounts": ["/srv/api -> /app"],
  "networks": ["backend"],
  "restartPolicy": "always"
}
```

Keys are stable and JSON objects are serialized in sorted-key order. The shared
operation runs `docker inspect <container> 2>/dev/null` with a 30 second timeout
and parses the first object in docker's result array. Invalid or empty JSON is a
failure instead of an empty success.

## Examples

```
ed machines docker inspect tuf api
ed machines docker inspect tuf api --json | jq -r '.environment[]'
```

## Where to go next

- [`ed machines docker`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
