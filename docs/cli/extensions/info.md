# Info

[CLI reference](../README.md) | [Extensions](./README.md)

Inspect one indexed extension.

```sh
ed extensions info <id> [--json]
```

The JSON object contains the same state fields as `ls`. A remembered enabled setting does not imply that a compatible worker is running. An unknown identifier returns exit code 1.
