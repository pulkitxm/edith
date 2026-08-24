# Performance audit

The checked audit lives in `performance/audit.json`. It covers startup, input,
repository reads, Git work, GitHub requests, extension discovery, cache behavior,
memory, main-thread work, large repositories, and slow networks. CI verifies that
every area retains live source or test evidence.

## Current findings

| Area | Finding | Guard |
| --- | --- | --- |
| Startup | Main and helper startup do synchronous setup before the first surface is ready. | Three Points of Interest intervals split main launch, helper services, and panel setup. |
| Input | Type-ahead and global hotkeys are event driven on the main thread. | Stable input interval names and a thread-context test. |
| Repository | Dashboard reads skip unchanged files. | The full load path is traced and the modification-time early return is checked. |
| Git | Usage collection owns the repository and Git subprocess pipeline. | The asynchronous utility process has one end-to-end interval and structured phase events. |
| GitHub | Contributor data uses a daily cache and failure fallback. | Cache and request intervals plus a one-read fallback test. |
| Extension discovery | Readiness is requested on demand and aggregate reports run concurrently. | The settings readiness request is traced. |
| Cache | Contributor hit and miss decisions are visible. | Corrupt-cache fallback decodes once. |
| Memory | Helper CPU, RSS, and optional idle wakeups have a machine-readable sampler. | Fixture tests lock schema, percentiles, and units. |
| Main thread | Every runtime interval records its begin and end thread context. | A deterministic test checks the main-thread signal. |
| Large repository | Dashboard JSON decoding is detached, but aggregation returns to the main actor. | Decode placement is checked and aggregation has its own interval. |
| Slow network | GitHub contributor requests stop after ten seconds and retain cached output. | Timeout source evidence and a local failing-network test. |

No universal timing budget is checked because CPU, RSS, disk, and network timing
vary materially by hardware and environment. Stable regression properties are
checked in CI. Timing changes are compared on the same machine, build, data set,
power mode, and network profile.

## Capture workflow

Build and launch the product, then collect a fixed sample count:

```sh
./scripts/bench-helper.sh --process EdithHelper --samples 30 --interval 1 --label "idle collapsed" > helper.json
./scripts/bench-helper.sh --process Edith --samples 30 --interval 1 --label "dashboard open" > main.json
```

Record launch and interaction intervals with the Points of Interest template:

```sh
xcrun xctrace record --template "Points of Interest" --launch -- dist/Edith.app/Contents/MacOS/Edith
```

For large-repository comparisons, reuse the same `usage.json` and record
`dashboard.load` and `dashboard.ingest`. For slow-network comparisons, apply the
same Network Link Conditioner profile and record `contributors.fetch`.

The deterministic harness can be verified without a running app:

```sh
make ci-performance
```

Further refactors should follow captured regressions. The first candidates are
shared extension-probe snapshots and moving dashboard aggregation off the main
actor if their intervals show material cost.
