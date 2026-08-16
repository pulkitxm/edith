# `ed color clear`

Forgets the whole picked-colour history.

Usage:

```
ed color clear [--json]
```

Options:

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--json` | flag | off | Emits one JSON document on stdout. |

There are no positional arguments, and there is no `--yes` guard: `clear` takes
effect the moment you run it.

`--json` shape:

```json
{
  "removed": 3
}
```

`removed` is how many swatches were in the history before it was emptied.

Examples:

```
ed color clear
ed color clear --json
```

```
$ ed color clear
cleared 3 colours
```

Behaviour: this removes the `colorPickerHistory` key from the shared defaults
suite, then posts the same `settingsChanged` notification `ed config set` sends.
Nothing re-reads the swatch history on that notification, so a running Edith can
still show the colours you cleared: the Recent Colors grid reloads the next time
the settings pane appears, and the eyedropper's menu only once the picker is
restarted or another colour is sampled. The post is fire and forget, so the
command needs nothing running and exits 0 either way. Clearing an already empty
history is reported as `cleared 0 colours` rather than as an error. There is no
per-swatch removal; the history is cleared whole or not at all.

The settings pane has no button for this. Its Recent Colors grid copies a
swatch in the configured copy format when you click it and offers all five
formats on right-click, but it cannot forget one, so `ed color clear` is the
only way to empty the history from any surface.

## Where to go next

- [`ed color`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
