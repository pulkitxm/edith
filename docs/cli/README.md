# Command line

The bundled `ed` launcher connects to this installation's running Edith app. Marketplace commands manage downloaded extensions. `invoke` sends JSON to an already enabled worker. Commands do not launch Edith or start an extension implicitly.

```sh
ed extensions ls
ed extensions install keepAwake
ed extensions enable keepAwake
ed extensions info keepAwake
ed extensions disable keepAwake
```

Use `Edith.app/Contents/MacOS/ed` to select a particular development app. The installed launcher reaches the installed app. Help and version work without an app session:

```sh
ed --help
ed --version
```

- [Conventions](./conventions.md): JSON, errors, limits, ownership, and cancellation.
- [Extensions](./extensions/README.md): list, inspect, install, update, enable, disable, and remove.
- [Invoke](./invoke/README.md): generic worker operations with JSON arguments or stdin.

Worker operation names and payloads belong to each downloaded extension. Use its current operation reference or integration configuration. The public gateway does not expose the old feature-specific command groups, config commands, or built-in manual aliases.
