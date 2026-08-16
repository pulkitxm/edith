# `ed app relaunch`

Quits both Edith processes and starts the app again, which is what a new
permission grant needs before it takes effect.

```
ed app relaunch [--json]
```

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--json` | flag | off | Emit JSON on stdout. |

`--json` shape:

```json
{
  "path": "/Applications/Edith.app",
  "relaunched": true
}
```

Examples:

```
ed app relaunch
ed app relaunch --json
```

Without `--json` it prints `relaunched Edith`, and only once the quit and the
launch have both happened. While it works it paints two transient spinner lines
on stderr, `waiting for Edith to quit` and then `starting Edith`; they are
skipped with `--json` and whenever stderr is not a terminal, so stdout stays one
document. This is the Permissions pane's relaunch button as a command, with a
longer reach: the button restarts the menu bar helper it lives in, while `ed`
takes both processes down. macOS hands a process its TCC answers when it starts,
so a grant you have just given is invisible until the app runs again.

It needs no running process, but it does need to find the app, which it checks
before it quits anything. When neither the bundle this binary sits inside nor
`/Applications/Edith.app` exists, it exits 4 with `Edith is not installed where
ed can find it`, hint `it looks in /Applications and alongside this binary`.

The order is: post the quit request, then terminate every process carrying
either bundle id, wait up to 8 seconds for them to go, force quit whatever is
still there and give that 3 seconds more, and only then launch the bundle and
wait for it to come up. With Edith already closed the quit step finishes at
once. The launch asks for a fresh instance and does not activate it, so Edith
comes back without taking focus.

Either half can fail the command, and neither failure is silent. If anything is
still alive after the force quit it exits 1 with `Edith did not quit, so it was
not relaunched`, hinting that you quit it from the menu bar and run the command
again, and nothing is launched. A launch that throws exits 1 with `could not
start Edith:` and the reason, hinting at opening the bundle from Finder.

Both processes come back: the helper is terminated along with the main window,
and the main app starts it again as it launches, so a grant that belongs to the
helper bundle rather than the main one is picked up by a relaunch too.

## Where to go next

- [`ed app`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
