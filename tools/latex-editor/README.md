# LaTeX editor

This package builds Edith's offline CodeMirror editor. The committed bundle and
license notices ship in `Packages/Edith/Sources/EdithKit/LaTeXEditor`.

```sh
bun install --frozen-lockfile
bun run build
bun run check
```

Keep dependency versions pinned. Rebuild the bundle after changing the source or
dependencies. The Swift editor tests exercise the bundled code in WebKit,
including source changes, undo, selection, search, and the save shortcut.
