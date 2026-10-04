# `ed code-stats folder`

[`ed code-stats`](./README.md)

[The `ed` command line](../README.md)

```bash
ed code-stats folder <path> [--json]
```

Chooses the folder that holds the mirror. The folder has to exist; a leading tilde expands to your home folder. The mirror can take gigabytes, so an external drive works well. A folder under `/Volumes` chosen here or in the settings counts as confirmed and is kept when Edith starts while the drive is unplugged. `--json` prints `path`, `changed` and `external`.
