# `ed __complete`

The hidden command behind shell completion. The installed zsh, bash and fish
scripts call it with the whole word list and the index of the word being
completed, and it prints one candidate per line. You never type it, but what it
does after a machine name is the interesting half of this page.

```
ed __complete --index <n> -- <words...>
```

## Options

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--index` | integer, zero based | `0` | Which word in `<words...>` is being completed. Word 0 is the program name. |
| `<words...>` | the command line so far | empty | Captured for passthrough, so flags in it are data. A single leading `--` is dropped. |

## Behaviour notes

When the first word after the program name is not a known command and does
match a configured machine, `ed` stops consulting its own tree and asks the
machine. What it asks depends on where the cursor is:

- At the first word after the machine name it asks for command names, with
  `compgen -c -- <prefix> | sort -u | head -2000`. That completes against the
  remote `PATH`, including tools `ed` has never heard of.
- After `cd`, `pushd` or `rmdir` it asks for directories only, with
  `compgen -d`, capped the same way.
- Anywhere else it uploads a small bash harness that sources
  `/usr/share/bash-completion/bash_completion` or `/etc/bash_completion`, runs
  `_completion_loader` for the command being typed, finds that command's
  registered `-F` function with `complete -p`, calls it with `COMP_WORDS`,
  `COMP_CWORD`, `COMP_LINE` and `COMP_POINT` set the way bash would, and prints
  `COMPREPLY`. When the command has no completion function or produces nothing,
  it falls back to `compgen -o default`, which is filenames.

So `ed tuf docker <TAB>` runs docker's own completion on the machine rather
than a list baked into `ed`:

```
$ ed __complete --index 3 -- ed tuf docker comp
compose
```

Two guards keep this from ever being slow. It runs only when a ControlMaster
socket for that machine is already alive, checked with `ssh -O check`, so
pressing TAB never dials a sleeping host; with no open connection you get no
candidates and exit 0. And the round trip itself is capped at six seconds, after
which the candidate list is empty rather than late.

The whole probe is prefixed with the same `cd` that commands get, so completion
follows `ed <machine> cd`. Candidates are filtered by the prefix you have typed,
case-sensitively, and deduplicated in the order the machine returned them.

The half-typed word is never interpolated into the remote line unquoted. The
command-name probe shell-quotes it, and the directory probe passes it to
`bash -c` as a positional parameter, so a prefix such as `$(touch /tmp/pwned)`
is completed against rather than run.

Under `ed machines <machine> ...` completion behaves the other way round: the
words are reordered the way the parser will see them and `ed`'s own tree
answers, so `ed machines tuf <TAB>` offers `docker`, `files` and the rest of the
group's verbs rather than remote programs.

## Where to go next

- [Running commands on a machine](./README.md), the rest of this group
- [All `ed` commands](../README.md)
