# `ed display status`

Shows every active display, the brightness route Edith selected, XDR availability, and Bluetooth sleep restoration state.

```bash
ed display status
ed display status --json
```

The method is `system` for macOS brightness control, `ddc` for external monitor hardware control, `software` for the reversible gamma fallback, or `unavailable` when no safe route exists.
