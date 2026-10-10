# Extensions

[CLI reference](../README.md)

All marketplace commands require the running Edith app and return JSON. Identifiers match the `id` values returned by `ls`.

- [Ls](./ls.md)
- [Info](./info.md)
- [Install](./install.md)
- [Update](./update.md)
- [Enable](./enable.md)
- [Disable](./disable.md)
- [Remove](./remove.md)

Only one marketplace mutation runs at a time. Concurrent mutations return an error; reads and independent worker invocations remain available. Installer verification, compatibility, dependencies, and recovery behavior match the app UI.
