# Machine power and processes

These commands inspect, wake, restart, shut down, and signal processes on configured remote Macs.

## Commands

| Command | Purpose |
| --- | --- |
| `ed machines power status <machine>` | Show connection and wake availability. |
| `ed machines power reboot <machine> --yes` | Restart the remote Mac. |
| `ed machines power shutdown <machine> --yes` | Shut down the remote Mac. |
| `ed machines power wake <machine>` | Send a wake-on-LAN packet. |
| `ed machines kill <machine> <pid>` | Signal one process. |
| `ed machines broadcast <command...>` | Run one command across configured Macs. |

Reboot and shutdown require `--yes`. Edith uses `sudo -n` by default. Save a sudo password with `ed machines edit <machine> --sudo-password-stdin` when the remote account requires one.

Wake requires a stored MAC address. Edith learns one from the remote Mac after a successful connection, or you can set it with `ed machines edit <machine> --mac <address>`.

## Related pages

- [`power status`](./power-status.md)
- [`reboot`](./power-reboot.md)
- [`shutdown`](./power-shutdown.md)
- [`wake`](./power-wake.md)
- [`kill`](./kill.md)
- [`broadcast`](./broadcast.md)
- [All `ed` commands](../README.md)
