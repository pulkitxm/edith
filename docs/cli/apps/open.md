# `ed apps open`

Opens an installed application by its exact bundle identifier. Focus Profiles
uses this operation when a profile declares an app launch set.

```
ed apps open <bundle-id> [--json]
```

The command resolves the application through macOS Launch Services. It exits 3
when no installed app has the requested bundle identifier and 1 when macOS
cannot launch the resolved application.

```bash
ed apps open com.apple.TextEdit
```

With `--json`, success is one object containing `bundleID`, `opened`, and the
new process `pid`. Diagnostics stay on stderr and failures leave stdout empty.

## Where to go next

- [`ed apps`](./README.md) for running app discovery and quit controls.
- [The `ed` command line](../README.md) for the rest of the reference.
