# Ls

[CLI reference](../README.md) | [Extensions](./README.md)

List the built-in marketplace index and the current state of each extension.

```sh
ed extensions ls [--json]
```

Each entry includes `id`, `title`, `installed`, `compatible`, `enabled`, `running`, `state`, `version`, `availableVersion`, `updateAvailable`, and `offline`. Listing does not fetch the catalog or start a worker.
