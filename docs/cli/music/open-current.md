# `ed music open-current`

Opens whichever player `ed music status` considers active. For Edith's own
player it opens the Music page. For Spotify or Apple Music it brings that
application forward.

```text
ed music open-current [--player <name>] [--json]
```

Use `--player builtin|spotify|apple` to select one running player explicitly.
The command does not launch a player merely to make it eligible for selection.
It exits 4 when no player is running, the selected application is unavailable,
or Edith's built-in player cannot answer.

JSON reports `operation`, `player`, `name`, `trackPath`, and `revealed`.
`revealed` is always false for this command.

- [`ed music`](./README.md)
- [All command groups](../README.md)
