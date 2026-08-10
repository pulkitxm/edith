# `ed usage sources`

Lists the agents that produced the history, which is where the ids `--source`
expects come from.

```
ed usage sources [--json]
```

## Options

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--json` | flag | off | Emit JSON on stdout |

## `--json` shape

A top-level array in the file's own order, not sorted. `label`, `tool`,
`machine` and `machineID` are `null` when the file carries no such metadata for
that id, and an agent that ran on this Mac carries no machine at all.

```json
[
  {
    "default": true,
    "id": "cli",
    "label": "Claude Code",
    "machine": null,
    "machineID": null,
    "tool": "Claude Code"
  },
  {
    "default": true,
    "id": "codex",
    "label": "Codex",
    "machine": null,
    "machineID": null,
    "tool": "Codex"
  },
  {
    "default": true,
    "id": "commandcode",
    "label": "Command Code",
    "machine": null,
    "machineID": null,
    "tool": "Command Code"
  },
  {
    "default": true,
    "id": "asus-tuf-7:cli",
    "label": "Claude Code · Asus TUF 7",
    "machine": "Asus TUF 7",
    "machineID": "4303DCF1-52D8-4075-AE9B-C2FD86D3821A",
    "tool": "Claude Code"
  },
  {
    "default": true,
    "id": "opencode",
    "label": "OpenCode",
    "machine": null,
    "machineID": null,
    "tool": "OpenCode"
  },
  {
    "default": true,
    "id": "cowork",
    "label": "Cowork",
    "machine": null,
    "machineID": null,
    "tool": "Claude Code"
  }
]
```

`default` says whether the id is in the file's `defaultSources`, which is the
set the dashboard pre-selects. It is not a filter `ed` applies anywhere: every
read command counts every source unless you pass `--source`.

## Examples

```
ed usage sources
ed usage sources --json
ed usage sources --json | jq -r '.[].id'
```

## Behaviour

Reads only, mutates nothing, and needs no app. It exits 4 with no `usage.json`
and 1 on a file that will not decode. It takes no window options, so there is no
exit 3 here.

The human table falls back to the id in the `LABEL` column when the file has no
label, and prints an empty `TOOL` cell when it has no tool. The `MACHINE` column
reads `this Mac` for a source with no machine metadata and the machine's name
for one the collector brought back over SSH; `--json` carries the same name as
`machine`, alongside the `machineID` the machine directory knows it by. When the
file lists no sources at all the command prints the header line by itself and
exits 0.

```
$ ed usage sources
ID              LABEL                     TOOL          MACHINE
cli             Claude Code               Claude Code   this Mac
codex           Codex                     Codex         this Mac
commandcode     Command Code              Command Code  this Mac
asus-tuf-7:cli  Claude Code · Asus TUF 7  Claude Code   Asus TUF 7
opencode        OpenCode                  OpenCode      this Mac
cowork          Cowork                    Claude Code   this Mac
```

## Where to go next

- [`ed usage`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
