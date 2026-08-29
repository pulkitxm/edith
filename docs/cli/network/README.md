# Network Diagnostics

Network Diagnostics is a read-only troubleshooting workspace for the current
Mac. It inspects the active interface, default route, DNS resolvers, Wi-Fi
metadata available to macOS, proxy and VPN configuration hints, and only the
remote targets you explicitly configure.

Run a local snapshot:

```sh
ed network diagnose
ed network diagnose --json
```

Add explicit probes when needed:

```sh
ed network diagnose --target example.com --dns example.com
ed network diagnose --https https://example.com --service example.com:443
```

Read the saved baseline with `ed network baseline`. Save a new one only from a
healthy run with `ed network diagnose --save-baseline`.

Public IP lookup is off by default. Enable it for one CLI run with `--public-ip`,
or use the workspace setting. Reports redact IP addresses, MAC addresses, URL
credentials, URL queries, and common secret fields before copy or export.

The extension never changes DNS, routes, proxies, VPNs, Wi-Fi, or network
services. Scheduled sampling is off by default, uses a minimum five-minute
interval, and stops when the extension is disabled or Edith quits.

[The `ed` command line](../README.md) covers the rest of the reference.
