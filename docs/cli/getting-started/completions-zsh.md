# `ed completions zsh`

Prints the zsh completion script on stdout so you can place it yourself.

```
ed completions zsh
```

No options of its own; `--help` and `--version` are generated. What it prints is
byte for byte what `install` would have written, so redirecting it into the
right directory is a complete substitute for installing, minus the profile edit
and the recorded path.

Examples

```
ed completions zsh
ed completions zsh > ~/.zsh/completions/_ed
```

The script starts with `#compdef ed edh edith` and defines `_ed_complete`, which
shells out to `ed __complete --index $((CURRENT-1)) -- "${words[@]}"`, treats a
line of `#files` as a call to `_files`, and passes everything else to `compadd`.
It handles being loaded either as an autoloaded function or sourced directly.

## Where to go next

- [Getting started with `ed`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
