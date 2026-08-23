# `ed music reveal-current`

Opens Edith's Music page at the folder containing the track currently loaded in
the built-in library player. If the active player is Spotify or Apple Music, or
the built-in player has no current track, it opens that player instead. This
matches clicking the notch artwork.

```text
ed music reveal-current [--player <name>] [--json]
```

Use `--player builtin|spotify|apple` to select one running player explicitly.
It exits 4 when no player is running or the chosen open or reveal action fails.

JSON reports `operation`, `player`, `name`, `trackPath`, and `revealed`.
`revealed` distinguishes library navigation from opening the player.

- [`ed music`](./README.md)
- [All command groups](../README.md)
