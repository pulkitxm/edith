# `ed machines docker df`

Reports docker's disk usage by object type, and how much of it is reclaimable.

```
ed machines docker df [--json] <machine>
```

## Arguments

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `<machine>` | machine name, ssh alias, id, or any unambiguous prefix | required | Which machine to ask. |

## Options

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--json` | flag | off | Emit JSON on stdout instead of the table. |
| `--help`, `-h` | flag | off | Print the help for this command on stdout and exit 0. |

```
$ ed machines tuf docker df
TYPE           TOTAL  ACTIVE  SIZE     RECLAIMABLE
Images         12     5       11.3 GB  3.6 GB
Containers     5      0       462 MB   462 MB
Local Volumes  10     4       11.7 GB  273 MB
Build Cache    0      0       0 B      0 B
```

## `--json` shape

```json
[
  {
    "active": 5,
    "reclaimableBytes": 3585000000,
    "sizeBytes": 11310000000,
    "total": 12,
    "type": "Images"
  },
  {
    "active": 4,
    "reclaimableBytes": 272700000,
    "sizeBytes": 11730000000,
    "total": 10,
    "type": "Local Volumes"
  }
]
```

- `type` is docker's own label: `Images`, `Containers`, `Local Volumes` and
  `Build Cache`, capitalised and spaced exactly like that.
- `total` is docker's `TotalCount` and `active` is how many of them are in use.
- `sizeBytes` and `reclaimableBytes` are parsed from docker's decimal strings.
  Docker prints reclaimable as `3.585GB (31%)`; the percentage is dropped and
  only the size is kept.

This is the report to read before pruning. `reclaimableBytes` for `Images` is
what `prune images` would free, and the `Local Volumes` row is what
`prune volumes` would free, which is data rather than cache.

## Examples

```
ed machines tuf docker df
ed machines tuf docker df --json | jq -r '.[] | "\(.type) \(.reclaimableBytes)"'
ed machines tuf docker df --json | jq 'map(.reclaimableBytes) | add'
```

## Behaviour notes

Read only, 45 second ceiling, `docker system df --format '{{json .}}'`. On a
busy daemon this is the slowest of the read commands, because docker walks the
image and volume trees to answer it.

## Where to go next

- [`ed machines docker`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
