# `ed extensions install`

[CLI reference](../README.md) | [Extensions](./README.md)

Download, verify and start an extension and its dependencies.

```sh
ed extensions install <id> [--json]
```

The extension is enabled and running when the command returns. An already installed extension returns an error; use `update` for it. An unavailable catalog or invalid package returns a JSON error and preserves the current installation.

The command allows up to 30 minutes for downloading and verification. Disconnecting or cancelling the command cancels its owned work.
