# `ed extensions enable`

[CLI reference](../README.md) | [Extensions](./README.md)

Start a compatible installed extension in the running app session.

```sh
ed extensions enable <id> [--json]
```

Download the extension first. Explicit enable can recover an extension with a pending disable, using the same controls as the app UI. A failed start returns an error and does not report a running worker.
