# `ed completions source`

Prints the fallback line that loads one completion script directly.

```
ed completions source [--shell <zsh|bash|fish>] [--json]
```

| Name | Type / values | Default | What it does |
| --- | --- | --- | --- |
| `--shell <shell>` | `zsh`, `bash` or `fish` | `zsh` | Select the completion script. |
| `--json` | flag | off | Emit `shell` and `source` in one JSON object. |

Plain output is ready to paste into the selected shell's startup file:

```
$ ed completions source
source $HOME/.local/share/zsh/site-functions/_ed
```

JSON keeps the selected shell explicit:

```json
{
  "shell": "fish",
  "source": "source $HOME/.config/fish/completions/ed.fish"
}
```

The path comes from the same shared operation used by the Copy button in
Terminal settings. It prefers the recorded installed script and otherwise
prints the line for the directory where installation would place it. An
unsupported shell exits 3 without output.

## Where to go next

- [`ed completions install`](./completions-install.md), write the scripts
- [Getting started with `ed`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
