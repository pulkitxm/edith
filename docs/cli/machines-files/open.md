# `ed machines files open`

Opens a Files window on a directory of the machine.

```
ed machines files open <machine> [path] [--json]
```

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `machine` | machine name, SSH alias, id or unambiguous prefix | required | Which machine to browse. |
| `path` | remote directory | the directory `ed <machine> cd` remembers for this terminal, else the machine's home | Where to open. |
| `--json` | flag | off | Emit JSON on stdout. |

```json
{
  "machine": "Asus TUF 7",
  "opened": true,
  "path": "/var/log"
}
```

```
ed machines files open tuf
ed machines files open tuf /var/log
ed tuf cd /srv/app && ed machines files open tuf
```

The window does not belong to Edith itself. It belongs to **Edith Files**, a
separate app that lives inside `Edith.app` at
`Contents/Library/Applications/Edith Files.app` and holds nothing but these
windows: no dashboard, no menu bar item, no usage collection. It quits when you
close the last window. That is why opening a folder from the shell costs a
window rather than the whole app.

So this verb never touches SSH itself. When Edith Files is not running, `ed`
launches it with the machine and path on its command line, which is the fast
path, a tenth of a second rather than the four seconds a full Edith took:

```
$ ed machines files open tuf /etc
opened /etc on Asus TUF 7
```

When it is already running, `ed` posts a request carrying the machine's id and
the path instead, and the running app opens another window and answers. Either
way the machine is connected if it was not already, so this works from cold, and
Edith itself can stay closed throughout.

`undo` still refuses when Edith is closed, because the history it reverses died
with the window that held it. A window, unlike a history, can be opened from
nothing.

The default path is what makes it worth typing. `ed tuf cd /srv/app` remembers a
directory per terminal, and `open` with no path reads that same record, so the
window lands where the shell is rather than at the home directory. Give a path
to override it, and give a path in a terminal that has never `cd`'d anywhere for
that machine, or the window opens at home.

Opening twice for the same machine and path brings the existing window forward
instead of stacking another one, which is the same rule the Files button in the
machine's tab bar follows.

What exits 4 is an Edith Files that cannot be started, either because it is not
inside the installed `Edith.app`, or because it did not come up within 20
seconds:

```
$ ed machines files open tuf
error: Edith Files is not installed where ed can find it
hint: it lives inside Edith.app; reinstall Edith and retry
```

So does a running one that never answers, reported the way `undo` reports it.
Both happen after the machine name has resolved, so an unknown machine still
exits 3 first.

## Where to go next

- [`ed machines files`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
