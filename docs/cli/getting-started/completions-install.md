# `ed completions install`

Writes completion scripts for the shells found on this Mac, and wires them into
the shell profile.

```
ed completions install [--json] [--shell <zsh|bash|fish>]
```

Options

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--json` | flag | off | Emit JSON on stdout instead of one line per shell |
| `--shell <shell>` | `zsh`, `bash` or `fish`, lowercased before matching | unset, meaning every detected shell | Install for one shell instead of all of them |

`--json` shape:

```json
{
  "installed": [
    {
      "hint": null,
      "path": "/Users/pulkit/.zsh/completions/_ed",
      "shell": "zsh"
    },
    {
      "hint": "add to ~/.bashrc: source /Users/pulkit/.local/share/bash-completion/completions/ed",
      "path": "/Users/pulkit/.local/share/bash-completion/completions/ed",
      "shell": "bash"
    }
  ]
}
```

Examples

```
ed completions install
ed completions install --shell zsh
ed completions install --json
```

Detection is by evidence on disk. zsh is always included. bash is included when
`~/.bashrc` or `~/.bash_profile` exists. fish is included when `~/.config/fish`
exists.

Where each script lands:

```
zsh    the first writable directory under $HOME in an interactive shell's
       $fpath, else ~/.local/share/zsh/site-functions/_ed
bash   ~/.local/share/bash-completion/completions/ed
fish   ~/.config/fish/completions/ed.fish
```

The zsh case really does ask zsh: it runs `/bin/zsh -ic 'print -l -- $fpath'`
and takes the first entry under your home directory that exists, is a directory
and is writable, which is why a machine with `~/.zsh/completions` on `$fpath`
gets the script there instead of in the fallback location.

Installing does three things beyond writing the file. It records the path in the
shared defaults under `completionScriptPaths`, which is what lets the app
rewrite an out-of-date script on launch when `completionsAutoRefresh` is on, and
that refresh only ever overwrites a file that already contains `__complete`. It
adds a managed block to `~/.zshrc` for zsh and `~/.bashrc` for bash, with
`$HOME` substituted back into the path:

```
# >>> edith completions >>>
source $HOME/.zsh/completions/_ed
# <<< edith completions <<<
```

And it prints the one line you may still need to add yourself, as `hint`. zsh
gets `add to ~/.zshrc, before compinit: fpath=(<directory> $fpath)` unless the
script went into a directory zsh already searches, in which case the hint is
null. bash gets `add to ~/.bashrc: source <directory>/ed`. fish never gets a
hint and never gets a profile edit, because fish loads that directory by itself.

The human output is one `shell: path` line per shell, with the hint indented two
spaces underneath it.

A `--shell` value that is not one of the three exits 3 before anything is
written:

```
$ ed completions install --shell nope
error: nope is not a supported shell
```

The shell is an option, not a positional, and completion offers the three names
in the positional slot as well. `ed completions install zsh` is rejected by the
parser and exits 2; write `--shell zsh`.

## Where to go next

- [Getting started with `ed`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
