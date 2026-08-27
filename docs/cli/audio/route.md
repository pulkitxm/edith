# `ed audio route`

Saves an output route for one application's bundle identifier.

```
ed audio route <bundle-id> <device-or-system> [--json]
```

The application is identified by a bundle identifier such as `com.spotify.client`.
`device` is an exact case-insensitive output name or Core Audio UID. Pass `system` to
remove the saved route and return that application to the current system output.

```
ed audio route com.spotify.client "USB Headphones"
ed audio route com.example.Player output-device-uid --json
ed audio route com.spotify.client system
```

Routes are stored by bundle identifier, so they apply again when the application restarts.
While Audio Controls is enabled, the existing audio mixer watches for producing apps and
creates the same Core Audio process tap used by its volume control. A route at 100 percent
still needs a tap because its output differs from the system default.

Application Audio access and macOS 14.4 or later are required for live routing. Saving a
route does not launch the application. If its target device is disconnected, the route
remains saved and is shown as unavailable until the device returns or the route is reset.

## Where to go next

- [`ed audio`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
