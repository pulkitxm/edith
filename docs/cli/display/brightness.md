# `ed display brightness`

[Display and Power](./README.md) | [CLI reference](../README.md)

Sets a whole percentage from 0 through 100 for all active displays or one display id from `ed display status`.

```bash
ed display brightness 60
ed display brightness 40 --display 1
ed display brightness 60 --json
```

Internal and Apple displays use macOS brightness control. External displays use DDC/CI when safely matched, with reversible software dimming as the fallback.
