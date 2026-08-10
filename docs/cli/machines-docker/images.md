# `ed machines docker images`

Lists the images on the machine with their size.

```
ed machines docker images [--json] <machine>
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
$ ed machines tuf docker images
ID            IMAGE                                                SIZE
e97bf9531916  ghcr.io/open-webui/open-webui:main                   5.1 GB
de3a4eab8fdf  postgres:16-alpine                                   294 MB
93aa428db0ae  postgres:17-alpine                                   297 MB
7ef7a41df1e0  lobehub/lobe-chat:latest                             617 MB
9eafe528d67a  redis/redis-stack:latest                             895 MB
af182398db7c  docker.elastic.co/kibana/kibana:9.0.0                1.2 GB
6cec5391a4c7  docker.elastic.co/elasticsearch/elasticsearch:9.0.0  1.4 GB
```

## `--json` shape

A top-level array, one object per image:

```json
[
  {
    "createdSince": "12 days ago",
    "dangling": false,
    "id": "sha256:e97bf95319168ab7fdfc5bd1e869f6a1cf6349bdf6d3e8fe16c733d2ca473491",
    "repository": "ghcr.io/open-webui/open-webui",
    "shortID": "e97bf9531916",
    "sizeBytes": 5090000000,
    "tag": "main"
  },
  {
    "createdSince": "4 weeks ago",
    "dangling": false,
    "id": "sha256:de3a4eab8fdfa507ea92aac488b916b08089e515db49b055fe71dfa271ba3a28",
    "repository": "postgres",
    "shortID": "de3a4eab8fdf",
    "sizeBytes": 294000000,
    "tag": "16-alpine"
  }
]
```

- `id` keeps docker's `sha256:` prefix; `shortID` strips it and keeps twelve
  characters, which is what the table shows and what `rmi` takes.
- `dangling` is true when either `repository` or `tag` is `<none>`, and the
  table prints such a row as `<none>:<none>`.
- `sizeBytes` is docker's human size parsed back into bytes. Docker prints
  decimal units, so `5.09GB` becomes `5090000000` rather than a byte-exact
  figure, and the table then re-renders it as `5.1 GB`.
- `createdSince` is docker's relative phrase, not a date.

## Examples

```
ed machines tuf docker images
ed machines tuf docker images --json | jq -r '.[] | select(.dangling) | .shortID'
ed machines tuf docker images --json | jq 'map(.sizeBytes) | add'
```

## Behaviour notes

Read only, 45 second ceiling. The remote command is
`docker images --no-trunc --format '{{json .}}'`, with no `-a`, so intermediate
build layers are not listed. Dangling images are, and `prune images` takes them
along with every other image no container uses.

## Where to go next

- [`ed machines docker`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
