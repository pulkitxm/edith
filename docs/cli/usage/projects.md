# `ed usage projects`

Cost and tokens per repository, with every matching folder grouped beneath its
GitHub repository.

```
ed usage projects [--range <range>] [--limit <n>] [--json]
```

## Options

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--range` | `today`, `week`, `month`, `all` | `all` | Which days to include. `week` is the current calendar week, from Monday through today |
| `--limit` | integer greater than zero | `25` | Show at most this many repositories, taken from the top of the cost order |
| `--json` | flag | off | Emit repository and folder details as JSON on stdout |

This is the one window command that does not take `--source`. It declares its
own `--range`, so `--source` here is an unknown option and exits 2.

## Output

The human table shows the repository name, cost and tokens. It does not include
paths, machine names or repository URLs.

```
$ ed usage projects --range week --limit 3
REPOSITORY  COST    TOKENS
edith       1340.77 1664124164
fable       988.15  919092634
macos       303.80  383653333
```

The JSON result is a top-level array sorted by `cost` descending and truncated
to `--limit`. Each repository includes its stable identity, GitHub URL and
folder breakdown.

```json
[
  {
    "repositoryID": "github.com/pulkitxm/edith",
    "repositoryName": "edith",
    "repositoryURL": "https://github.com/pulkitxm/edith",
    "cost": 1340.774043018298,
    "tokens": 1664124164,
    "folders": [
      {
        "folderName": "edith",
        "path": "/Users/pulkit/scripts/edith",
        "machineName": null,
        "machineID": null,
        "cost": 810.235,
        "tokens": 1012304402
      },
      {
        "folderName": "edith",
        "path": "/home/pulkit/code/edith",
        "machineName": "Asus TUF 7",
        "machineID": "0B481F65-F946-4636-AB36-E4508EB67E6A",
        "cost": 530.539043018298,
        "tokens": 651819762
      }
    ]
  }
]
```

## Examples

```
ed usage projects
ed usage projects --range week --limit 5
ed usage projects --range today --json | jq -r '.[] | .repositoryName'
ed usage projects --json | jq '.[] | {name: .repositoryName, folders}'
```

## Behaviour

Folders with the same GitHub remote are one repository even when they are on
different machines. A repository's visible name is its final GitHub path
component. Repositories with the same visible name remain separate because
`repositoryID`, not the display name, is the grouping key. Repositories without
a GitHub remote use a folder identity and are not merged across unrelated paths.

For each day and source, project values are normalized to that source's
canonical cost and token totals. Usage with no matching folder detail appears
under `Unattributed`, so repository totals still reconcile with the summary.

The command reads only, mutates nothing, and needs no app. It exits 4 with no
`usage.json`, 1 on a file that will not decode, 3 on a bad `--range`, and 2 on
`--limit 0` or a negative limit.

## Where to go next

- [`ed usage`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
