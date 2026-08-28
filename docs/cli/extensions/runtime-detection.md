# Extension runtime detection

`ed extensions status`, `verify`, and `doctor` inspect the runtime behind every
enabled extension. The Extensions settings pane uses the same probe. These
checks are read-only and do not start a service, request access, create content,
or repair stored data.

The probe keeps setup readiness and runtime state separate:

- `state.phase` answers whether setup is complete and healthy.
- `state.runtimePhase` answers whether the runtime is installed, uninstalled,
  empty, loading, unsupported, or in an error state.
- `checks` explains the source of each conclusion.
- `remediation` lists commands that can safely move the extension forward.

An adapter failure is different from incomplete setup. Missing configuration
produces `needsSetup`. Corrupt data, an unreadable backend, or an operating
system query failure produces `failed` with runtime phase `error`.

## What each adapter checks

| Extension | Live installation and configuration checks | Content or runtime check | Recovery and verification |
| --- | --- | --- | --- |
| Attention | tracking is enabled with at least one selected source | application or browser tracking is configured | `ed attention summary --json`; `ed extensions verify attention` |
| Agent Usage | bundled collector plus at least one verified provider executable | refresh lock and decoded `usage.json` daily samples | `ed usage refresh`; `ed usage --json` |
| Herdr | Herdr presence on this Mac or a configured machine | collected sessions and per-host errors | `ed herdr ls --json`; `ed extensions verify herdr` |
| Quinjet | verified Quinjet executable, terminal and theme values, and cmux when selected | terminal integration can be resolved | `ed tools install quinjet`; `ed config set quinjetTerminal embedded` |
| System | built-in running-application module | regular applications visible through AppKit | `ed apps ls --json`; `ed app relaunch` |
| Machines | readable machine registry with valid names, hosts, and SSH ports | configured machine count | `ed machines ls --json`; `ed machines add --help` |
| Companion | configured endpoint | backend health checks and optional dependency health | `ed companion doctor --json` |
| CPU & Memory | built-in metrics module | CPU tick sample and physical memory availability | `ed system stats --json`; `ed app relaunch` |
| Mic Mute | built-in Core Audio module | input device discovery and input stream count | `ed config ls --group micmute --json`; `ed app relaunch` |
| Lid Awake | privileged helper registration and approval state | Service Management reports the helper enabled | `ed lid-awake status --json`; approve Login Items when requested |
| Music | configured library path exists and is a directory | recursive supported-track count and optional yt-dlp version | `ed music rescan`; `ed tools install yt-dlp` |
| Calendar | live EventKit authorization | readable calendar count | `ed permissions request calendar`; `ed calendar ls --json` |
| Notch Shelf | decodable shelf index and, when Audio Mixer is enabled, macOS 14.4 or later | parked item count and missing backing files; Audio Mixer is omitted on unsupported systems | `ed shelf ls --json`; `ed permissions settings applicationAudio` |
| Clipboard | decodable JSONL index | entry count and missing blob payloads | `ed clipboard stats --json`; `ed clipboard ls --json` |
| Focus Dim | finite intensity and animation values plus a valid display mode | active display count | `ed config ls --group focusdim --json`; `ed permissions refresh` |
| Presenter | at least one protected data category and coherent detector settings | manual protection or automatic detectors can operate | `ed presenter status --json`; `ed config ls --group presenter --json` |
| Color Picker | valid copy format, color profile, history limit, and decodable history | active display and saved sample count | `ed color ls --json`; `ed permissions refresh` |

## Agent workflow

Use JSON and branch on fields rather than matching human text:

```
ed extensions status --json |
  jq '.[] | select(.verified == false) |
      {id, phase: .state.phase, runtime: .state.runtimePhase, remediation}'
```

For one extension:

```
ed extensions verify music --json
ed extensions doctor clipboard --json
```

Treat these outcomes differently:

| Result | Agent action |
| --- | --- |
| `disabled` | Ask before enabling, or run `setup` when enablement is already authorized |
| `needsSetup` | Run a listed noninteractive remediation command, then verify again |
| `degraded` | Continue with the core workflow and report the unavailable optional feature |
| `unavailable` | Stop retrying on this platform |
| `failed` | Preserve the failure detail, run the listed diagnostic, then verify again |
| runtime `empty` | Create or import the extension's first content item |
| runtime `loading` | Wait for the current discovery or refresh operation, then retry |

`setup --dry-run --json` is the safe way to inspect enablement, required tools,
and remaining work before changing preferences.

## Where to go next

- [`ed extensions status`](./status.md) for the compact registry report
- [`ed extensions verify`](./verify.md) for one complete readiness report
- [`ed extensions doctor`](./doctor.md) for diagnostics across the registry
- [`ed extensions`](./README.md) for setup, states, and exit-code contracts
- [All `ed` commands](../README.md)
