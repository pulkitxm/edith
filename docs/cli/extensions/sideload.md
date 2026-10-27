# `ed extensions sideload`

[CLI reference](../README.md) | [Extensions](./README.md)

Install a locally built development package into a development build.

```sh
ed extensions sideload <package.zip|package directory> [--json]
```

Only development builds accept this command; release builds refuse it. The package must be an ad-hoc signed development build for this build's host ABI, architecture and macOS version, with its dependencies already installed. It replaces the catalog version in this slot and starts or restarts the extension. Build and sideload in one step with `make extension-sideload EXTENSION=<id>`.
