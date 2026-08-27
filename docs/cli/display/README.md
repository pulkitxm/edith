# Display and Power

Display and Power controls the built-in display and connected monitors without taking over Edith's existing System or Lid Awake features.

Internal displays and supported Apple displays use macOS brightness control. A single external monitor uses DDC/CI when its connection exposes the monitor's hardware controls. Other external configurations use a reversible per-display gamma adjustment, so adapters without DDC still have a useful brightness control. Disabling the extension or quitting Edith restores every software gamma table it changed.

On a supported MacBook Pro, XDR extra brightness uses available HDR headroom. macOS can reduce that headroom for battery, thermal, or display-profile reasons. The overlay closes immediately when the feature or extension stops.

Bluetooth sleep control records whether Bluetooth was on before sleep. It restores Bluetooth on wake only when Edith turned it off, including recovery after an interrupted sleep session. Bluetooth that was already off is never enabled.

Display and Power does not prevent sleep and does not alter lid-close behavior. Use System for ordinary sleep prevention and Lid Awake for closed-lid sessions.

## Commands

```bash
ed display status
ed display brightness 60
ed display brightness 40 --display 1
ed display xdr 50
ed display xdr off
ed display bluetooth-sleep on
```

Add `--json` to status and mutation commands for structured output.
