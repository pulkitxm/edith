# `ed extensions`

Download, inspect and manage Edith's optional extensions through the running app.
The app owns the marketplace, enabled selections and extension lifecycle. Extension
engines run inside Edith, so an active extension reports the app's process id.

Downloading and enabling are separate actions. Installation verifies a compatible
package and leaves it disabled. Enabling starts its work. Disabling stops that work
while retaining the download and user data. Removal deletes package files after
outstanding leases are released and retains user data, including usage history.

## Commands

| Command | What it does |
| --- | --- |
| `ed extensions` | List the marketplace index and installed state |
| `ed extensions ls` | List every indexed extension without fetching the catalog |
| `ed extensions info <id>` | Inspect installation, compatibility, version and active state |
| `ed extensions install <id>` | Download and verify a compatible extension |
| `ed extensions update <id>` | Replace an installed extension with a compatible update |
| `ed extensions enable <id>` | Start a downloaded extension |
| `ed extensions disable <id>` | Stop an extension and retain its download |
| `ed extensions remove <id>` | Remove its package files while retaining user data |
| `ed extensions status [id]` | Read setup and runtime readiness |
| `ed extensions verify <id>` | Run the owning extension's readiness checks |
| `ed extensions doctor [id]` | Diagnose setup and runtime problems |
| `ed extensions setup <id>` | Run owned noninteractive setup, with `--dry-run` for a preview |

Use `--json` for structured output. A remembered enabled selection does not imply
that an extension is active. Inspect `compatible`, `running`, `disablePending` and
`removalPending` before relying on it. An incompatible or unavailable package stays
inactive until a compatible version is available.

## Reference

- [ls](./ls.md) and [info](./info.md)
- [install](./install.md), [update](./update.md) and [remove](./remove.md)
- [enable](./enable.md) and [disable](./disable.md)
- [status](./status.md), [verify](./verify.md) and [doctor](./doctor.md)
- [setup](./setup.md) and [runtime detection](./runtime-detection.md)
- [Marketplace behavior](https://github.com/pulkitxm/edith/blob/main/docs/extension-marketplace.md)
- [All commands](../README.md)
