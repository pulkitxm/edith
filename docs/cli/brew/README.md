# `ed brew`

`ed brew` is the command-line surface for Homebrew Manager. It searches formulae and casks, lists installed packages and updates, and performs bounded package changes through the local Homebrew executable.

[The `ed` command line](../README.md)

| Command | What it does |
| --- | --- |
| [`ed brew status`](./status.md) | Reports whether Homebrew is available. |
| [`ed brew ls`](./ls.md) | Lists installed packages and available updates. |
| [`ed brew search`](./search.md) | Searches formulae or casks. |
| [`ed brew install`](./install.md) | Installs one exact package. |
| [`ed brew upgrade`](./upgrade.md) | Upgrades one exact package. |
| [`ed brew uninstall`](./uninstall.md) | Previews an uninstall, or applies it with `--yes`. |

Commands run locally without requiring Edith to be open. Automatic Homebrew updates, analytics, environment hints, and interactive prompts are disabled. Read operations have a 60-second limit, mutations have a 30-minute limit, retained output is capped at 2 MB, and cancellation terminates the complete process group.
