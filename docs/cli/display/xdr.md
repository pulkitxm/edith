# `ed display xdr`

[Display and Power](./README.md) | [CLI reference](../README.md)

Sets extra brightness on a supported built-in XDR display, or disables the boost.

```bash
ed display xdr 50
ed display xdr off
ed display xdr 50 --json
```

The level is a whole percentage from 0 through 100. The available boost follows the current HDR headroom reported by macOS.
