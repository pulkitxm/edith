# `ed extensions install`

[CLI reference](../README.md) | [Extensions](./README.md)

Download and verify an extension and its dependencies.

```sh
ed extensions install <id> [--json]
```

The extension remains disabled until explicitly enabled. An already installed extension returns an error; use `update` for it. An unavailable catalog or invalid package returns a JSON error and preserves the current installation.
