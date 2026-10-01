# `ed seo run`

[`ed seo`](./README.md)

[The `ed` command line](../README.md)

```bash
ed seo run <id> [--run <id>] [--offset <n>] [--severity error|warning|notice] [--query <text>] [--platform facebook|x|linkedin|slack|discord] [--json]
```

Reads one saved run. `--offset 0` is the newest and higher offsets step to older runs. `--run` selects a run id and overrides the offset. Omit `--severity` to include every issue. `--query` keeps pages whose URL or title contains the text. `--platform` picks the social card the project screen previews. JSON pages include `issues`, `scores`, and `social`.
