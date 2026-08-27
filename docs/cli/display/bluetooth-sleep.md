# `ed display bluetooth-sleep`

[Display and Power](./README.md) | [CLI reference](../README.md)

Chooses whether Edith turns Bluetooth off while the Mac sleeps.

```bash
ed display bluetooth-sleep on
ed display bluetooth-sleep off
ed display bluetooth-sleep on --json
```

Edith restores Bluetooth on wake only when it turned Bluetooth off. Disabling the setting, disabling the extension, or quitting also pays any pending restoration debt.
