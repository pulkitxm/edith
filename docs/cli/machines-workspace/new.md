# `ed machines workspace new`

Builds a workspace with one pane per machine.

Usage:

```
ed machines workspace new <machines>... [--screen <screen>] [--name <name>] [--json]
```

Arguments:

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `<machines>...` | one or more machine names, ssh aliases, ids or unambiguous prefixes | at least one required | Gives each named machine a pane, in the order you list them. |

Options:

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--screen` | `overview`, `processes`, `docker`, `terminal`, `files`, `tools` | `overview` | What every pane shows. One value for the whole workspace; retarget individual panes afterwards with `point`. |
| `--name` | text | the machine names joined with ` + ` | What to call the workspace. |
| `--json` | flag | off | Emits one JSON document on stdout. |

The `--screen` help text in `ed machines workspace new --help` lists five
screens and omits `tools`; the value is accepted all the same, and the error
you get from a bad one lists all six.

`--json` shape, the new workspace, always current:

```json
{
  "current": true,
  "id": "1F2C77B0-9A34-4C51-B0E7-6D9E42A31C08",
  "machines": 2,
  "name": "Asus TUF 7 + mini",
  "panes": 2
}
```

Examples:

```
ed machines workspace new tuf
ed machines workspace new tuf mini --screen terminal
ed machines workspace new tuf mini --name "Deploy" --screen docker
ed machines workspace new tuf tuf tuf --screen files --json
```

```
$ ed machines workspace new tuf mini --screen terminal
made Asus TUF 7 + mini with 2 pane(s)
```

Behaviour: `new` is the Workspace toolbar's Layout menu as a command. One
machine gives a single pane with no split at all; several give one horizontal
split with equal ratios, tiled left to right in the order you named them. Every
machine is resolved before anything is written, so an unknown or ambiguous name
exits 3 and no workspace is created.

The new workspace is appended to the file and becomes current, so `new` always
switches you. Names are not checked for uniqueness: making two workspaces called
`Deploy` leaves both in the file, and every later lookup by that name finds the
first one, which makes the second reachable only by its id. Pass `--name` if you
are scripting this.

Repeating a machine is allowed and gives it a pane each time, which is how you
get four panes on one machine, every one of them on the single `--screen` you
named until `point` sends them elsewhere. The `machines` count in the JSON
counts distinct machines, so that workspace reports four panes and one machine.

An empty machine list is caught by the parser and exits 2 with
`Missing expected argument '<machines> ...'`; the command's own guard behind it,
`name at least one machine`, exits 1 and is only reachable if the parser ever
lets an empty list through.

## Where to go next

- [`ed machines workspace`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
