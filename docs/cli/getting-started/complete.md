# `ed __complete`

The hidden command every completion script calls. It takes the command line you
are typing and prints the candidates for one word of it.

```
ed __complete [--index <n>] [--] <words>...
```

Arguments and options

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--index <n>` | integer, zero based | `0` | Which word of `<words>` is being completed |
| `<words>` | everything else, captured verbatim | empty | The whole command line, including the program name at index 0. A leading `--` is dropped |

It is marked as not displayed, so it never appears in `ed --help`, but it is a
reserved name, so a machine called `__complete` can never shadow it. It has no
`--json`: the output is one candidate per line, and the literal line `#files`
means "also offer local file names here". No candidates means no output, and it
exits 0 either way.

It is also the one command with no working `--help`. Everything that is not
`--index` is captured verbatim, so `ed __complete --help` completes the word
`--help` and prints it straight back rather than printing help, and
`ed __complete --version` does the same instead of printing the version.

Examples

```
$ ed __complete --index 1 -- ed co
completions
config
color

$ ed __complete --index 4 -- ed config set limitsProvider ""
claude
codex

$ ed __complete --index 3 -- ed shelf add ""
#files
```

## Where to go next

- [Getting started with `ed`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
