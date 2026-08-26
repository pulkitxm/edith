# `ed machines snippets run`

Runs one saved snippet on its selected machine through the same shared execution
used by the app's Run button.

```
ed machines snippets run <machine> <index> [--json]
```

## Arguments

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `<machine>` | machine name, ssh alias, id, or unambiguous prefix | required | Which machine to use. |
| `<index>` | integer, counting from 1 | required | Which entry from `ed machines snippets ls` to run. |

## Options

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--json` | flag | off | Emit the machine, operation, stdout, stderr and snippet record as JSON. |
| `--help`, `-h` | flag | off | Print help and exit 0. |

Plain mode keeps the command's stdout and stderr on their matching local
streams. JSON returns both streams separately in a stable object:

```json
{
  "machine": "Box",
  "operation": "machines.snippets.run",
  "stderr": "",
  "stdout": "active\n",
  "snippet": {
    "command": "systemctl is-active nginx",
    "id": "F8D5CE93-C9B4-4A05-9109-9AEB1BD806BA",
    "index": 1,
    "sharedAcrossMachines": false,
    "title": "nginx"
  }
}
```

The saved command is sent verbatim with a 120 second timeout. The index is
resolved before a connection is opened, so an out-of-range index exits 3 without
contacting the machine. Machine identity is pinned with the selected snippet
before connecting. A nonzero remote exit reports both streams as diagnostics.

## Examples

```
ed machines snippets run box 1
ed machines snippets run box 1 --json | jq -r '.stdout'
```

## Where to go next

- [`ed machines`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
