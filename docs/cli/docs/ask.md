# `ed docs ask`

Ranks the commands that handle a plain-language request, with where each one is
documented. This is the Ask bar on the Docs page.

```
ed docs ask <request> [--json]
```

```sh
ed docs ask "free up docker space on my server"
ed docs ask how much of my claude limit is left --json
```

With a TypeSafe key saved, Jev picks the command group and then the command,
and `engine` is `jev`. Without a key no request leaves this Mac: a local search
over command names, page titles, headings and summaries answers, and `engine` is
`search`. The local search also answers when Jev fails or is unsure, so the
command always exits 0 with a ranking.

## Options

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--json` | flag | off | Emit JSON on stdout |

The human form is a table of `COMMAND`, `CONFIDENCE` and `PAGE`, and the engine
that answered goes to stderr.

## `--json` shape

```json
{
  "engine": "search",
  "latencyMs": 2,
  "picks": [
    {
      "anchor": null,
      "command": "ed machines docker prune",
      "page": "machines-docker/prune.md",
      "probability": 0.81,
      "summary": "Reclaims space by removing unused docker objects."
    }
  ],
  "request": "free up docker space on my server"
}
```

`picks` holds at most five commands, best first, and their probabilities add up
to about 1. `anchor` names the section when the command shares a page with
others.

- [`ed docs`](./README.md)
- [All command groups](../README.md)
