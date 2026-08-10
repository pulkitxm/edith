# `ed machines forwards add`

Saves a port forward against a machine. It saves only; use `on` to open it.

```
ed machines forwards add <machine> --local <n> --remote <n>
                                   [--remote-host <h>] [--title <t>] [--json]
```

## Arguments

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `<machine>` | string, required | none | Machine name, ssh alias, id or unambiguous prefix. |

## Options

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--local` | integer 1 to 65535, **required** | none | Port to open on this Mac. Bound to `127.0.0.1`, not to every interface. |
| `--remote` | integer 1 to 65535, **required** | none | Port to reach on the far side. |
| `--remote-host` | string | `localhost` | The host the far side should connect to, resolved on the machine. Point it at another box on that network to reach through. |
| `--title` | string | `""` | What to call it in the list. |
| `--json` | flag | off | Emit JSON on stdout instead of the line. |
| `--help`, `-h` | flag | off | Print the help for this command on stdout and exit 0. |

```
$ ed machines forwards add tuf --local 8080 --remote 80 --title "web"
added 127.0.0.1:8080:localhost:80 on Asus TUF 7
```

## `--json` shape

The same object `forwards ls` emits, with one difference worth knowing:

```json
{
  "id": "1E0B4C4A-5D3B-4F5B-9D2E-0F1A2B3C4D5E",
  "index": 0,
  "localPort": 8080,
  "remoteHost": "localhost",
  "remotePort": 80,
  "spec": "127.0.0.1:8080:localhost:80",
  "title": "web"
}
```

`index` is `0` here, not the new row's position. The number is only meaningful
in a listing, so run `ed machines forwards ls <machine> --json` afterwards if
you need the position to pass to `on`.

## Examples

```
ed machines forwards add tuf --local 8080 --remote 80
ed machines forwards add tuf --local 5433 --remote 5432 --title postgres
ed machines forwards add tuf --local 9000 --remote 9000 --remote-host 10.0.0.7
```

## Behaviour notes

Appends to `forwards.json` and posts `machinesChanged`. Two forwards on one
machine cannot claim the same local port:

```
$ ed machines forwards add tuf --local 3000 --remote 3000
error: Asus TUF 7 already forwards local port 3000
hint: run `ed machines forwards ls Asus TUF 7` to see them
```

That exits 1, as does a port outside 1 to 65535. The check is per machine, so
two different machines may both save local port 3000; only one of them can have
it open at a time, and the second `on` is what fails.

## Where to go next

- [`ed machines`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
