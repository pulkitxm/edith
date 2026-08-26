# libghostty

Edith links Ghostty's terminal engine through `libghostty`, the same C API
Ghostty's own macOS app uses.

## Building

```bash
make ghostty
```

That clones Ghostty into `vendor/ghostty`, checks out the pinned commit and
builds `vendor/GhosttyKit.xcframework`. The directory is ignored by git.

## What is pinned, and why

| | |
|---|---|
| Ghostty | `88f57ee` (1.3.2-main) |
| Zig | 0.16.0 |

The pin is a `main` commit rather than the `v1.3.1` tag on purpose. Building
v1.3.1 with Zig 0.15.2 produces static archives whose members are not 8-byte
aligned, and the linker shipped with Xcode 26 rejects them. Ghostty's own macOS
app fails to link the same way, so this is not something Edith can configure
around. The pinned commit builds clean.

Upstream states in `build.zig` that libghostty "is not stable for general
purpose use", so the commit is pinned exactly and upgrades are deliberate.

## Using it

`ghostty_init` has to run before any other call, or the first call segfaults.

```swift
let rc = ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv)
```

A surface renders into an `NSView` handed to it through
`ghostty_surface_config_s.platform.macos.nsview`, and takes its process
settings from `command`, `env_vars` and `working_directory`, which is what
`TerminalLaunchRequest` already carries.

## Sizes

| | |
|---|---|
| `libghostty-internal.a` | 135 MB, self-contained, arm64, ReleaseFast |
| xcframework | 129 MB |
| zipped | 32 MB |
| contribution to a linked binary | ~19 MB |
