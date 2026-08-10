# `ed completions fish`

Prints the fish completion script on stdout.

```
ed completions fish
```

No options of its own; `--help` and `--version` are generated.

Examples

```
ed completions fish
ed completions fish > ~/.config/fish/completions/ed.fish
```

It defines `__ed_complete`, calls `ed __complete --index (count $tokens) --
$tokens $current`, expands `#files` with `__fish_complete_path`, and registers
the function for all three command names.

## Where to go next

- [Getting started with `ed`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
