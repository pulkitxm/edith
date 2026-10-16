# `ed database connections add`

Tests a database connection through the authenticated local broker, then saves it only when the test succeeds.

```
ed database connections add <name> --product <product> [options]
```

Supported products are `postgresql`, `sqlite`, `redis`, `valkey`, and `mongodb`.

Network connections default to `127.0.0.1` and the product's standard port. SQLite requires `--path`. PostgreSQL and MongoDB require `--username`. Use `--database` for a default database or Redis logical database. MongoDB authentication defaults to `admin` and can be changed with `--authentication-database`.

## Credentials

Pass `--password-stdin` to read one password from standard input. The password is stored in Keychain before the broker test and is removed if the test or save fails. Passwords, secret references, and authentication sources are never printed.

## Safety defaults

New connections default to the `development` environment, confirmation-required protection, required read-only access, and mutation-preview enforcement. Override them with `--environment`, `--environment-label`, `--protection`, `--read-only`, and `--production-policy`.

## Output

Plain output prints the saved connection name, ID, detected product, and test latency. `--json` emits one document containing the safe saved connection projection, detected product, and latency.

## Examples

```
ed database connections add local --product postgresql --username postgres --database app
printf '%s\n' "$DB_PASSWORD" | ed database connections add staging --product postgresql --host 127.0.0.1 --port 55432 --username app --database app --password-stdin --environment testing --environment-label "TUF Windows" --json
ed database connections add cache --product valkey --host 127.0.0.1 --port 56380
ed database connections add local-file --product sqlite --path ./data.sqlite
```

## Exit codes

| Code | Meaning |
| --- | --- |
| 0 | The connection tested successfully and was saved. |
| 1 | The broker rejected the test or save. |
| 2 | An argument or connection definition was invalid. |
| 3 | A requested product or policy name was not found. |
| 4 | The broker or database endpoint was unavailable. |

## Where to go next

- [`ed database connections`](./connections.md)
- [`ed database connections list`](./connections-list.md)
- [All `ed` commands](../README.md)
- [CLI conventions and contracts](../conventions.md)
