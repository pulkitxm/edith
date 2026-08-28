# `ed install`

Links `ed`, `edh` and `edith` into a directory on your `PATH`.

```
ed install [--json] [--directory <directory>]
```

Options

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--json` | flag | off | Emit JSON on stdout instead of a sentence |
| `--directory <directory>` | path, `~` expanded | `/usr/local/bin` when writable, otherwise `~/.local/bin` | Link into this directory instead of the default |

`--json` shape:

```json
{
  "directory": "/Users/pulkit/.local/bin",
  "linked": [
    "ed",
    "edh",
    "edith"
  ],
  "message": null,
  "onPath": true,
  "skipped": []
}
```

Examples

```
ed install
ed install --directory ~/bin
ed install --json
/Applications/Edith.app/Contents/MacOS/ed install
```

A name that is already linked to the right binary is left alone and appears in
neither `linked` nor `skipped`, so a second `ed install` in a row reports an
empty list and still exits 0. A name occupied by a real file is left alone and
listed in `skipped`, because the installer never overwrites something it did not
create. A name occupied by a symlink is replaced whatever it points at, which is
how a stale link from an older install gets repaired.

`onPath` compares the target directory against the entries of `PATH` after
standardising both, so a match is exact rather than textual. When it is false
the human output adds `note: <directory> is not on PATH` on stderr and still
exits 0, because the links were made either way.

`message` is null on success. A missing bundled binary, an occupied unmanaged
path, or a failed link is reported on stderr and exits 1 before a success
document is emitted. The Install button in Terminal settings calls the same
typed operation and shows the same failure.

The installer finds the binaries to link by walking up from the directory of the
executable that is running and taking the first directory that holds an
executable called `ed`, checking `Contents/MacOS` at each step. Run it through a
link that is already on your `PATH` and that search stops at the link directory
itself, so `ed` is relinked onto itself and stops working, and the remaining
names are then reported as skipped because their shared source no longer
resolves. Run it from the copy inside the app, or from the build product, never
through the link:

```
/Applications/Edith.app/Contents/MacOS/ed install
build/Build/Products/Release/ed install --directory $HOME/.local/bin
```

That second line is what `make cli` runs. If the self-link has already happened,
the first line puts everything back.

## Where to go next

- [Getting started with `ed`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
