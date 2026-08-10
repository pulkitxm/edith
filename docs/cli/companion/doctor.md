# `ed companion doctor`

Asks the backend to check each service it depends on.

Usage:

```
ed companion doctor [--json] [--endpoint <url>]
```

Options:

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--json` | flag | off | Emits one JSON document on stdout. |
| `--endpoint` | URL | environment or local default | Uses this Companion API base URL. |

`--json` shape:

```json
{
  "checks": [
    { "detail": "connected", "name": "postgres", "ok": true },
    { "detail": "3 of 3 migrations applied", "name": "migrations", "ok": true },
    { "detail": "installed", "name": "pgvector", "ok": true },
    { "detail": "connected", "name": "redis", "ok": true },
    { "detail": "writable", "name": "vault", "ok": true }
  ],
  "ok": true
}
```

`ok` is true only when every check passed. Each item in `checks` has the
dependency `name`, its own Boolean `ok`, and a human-readable `detail` from the
backend.

Examples:

```
$ ed companion doctor
postgres  ok  connected
migrations  ok  3 of 3 migrations applied
pgvector  ok  installed
redis  ok  connected
vault  ok  writable

$ ed companion doctor --json
{
  "checks": [
    { "detail": "connected", "name": "postgres", "ok": true }
  ],
  "ok": true
}
```

Behaviour: `doctor` decodes the health report even when the API returns HTTP
503. A reachable but unhealthy backend still exits 0 because health lives in
the payload, where scripts can inspect `ok`. Failure to reach the API exits 4.

## Where to go next

- [`ed companion`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
