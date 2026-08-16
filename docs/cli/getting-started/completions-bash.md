# `ed completions bash`

Prints the bash completion script on stdout.

```
ed completions bash
```

No options of its own; `--help` and `--version` are generated.

Examples

```
ed completions bash
ed completions bash > ~/.local/share/bash-completion/completions/ed
```

It defines `_ed_complete`, calls `ed __complete --index "$COMP_CWORD" --
"${COMP_WORDS[@]}"`, expands a `#files` line with `compgen -f`, and ends with
`complete -o bashdefault -F _ed_complete ed edh edith`.

## Where to go next

- [Getting started with `ed`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
