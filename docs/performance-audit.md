# Performance audit

The checked audit lives in `performance/audit.json`. It covers startup, input,
repository reads, Git work, GitHub requests, extension discovery, bounded UI rendering,
cache behavior, background workers, generation safety, memory, main-thread work, large
repositories, and slow networks. CI verifies that every area retains live source or test
evidence.

## Current findings

| Area | Finding | Guard |
| --- | --- | --- |
| Startup | The main window and helper panel precede deferred service setup. | Generation-owned startup phases yield between independent service groups and cancel on supersession or termination. |
| Input | Type-ahead and global hotkeys are event driven, while terminal responders keep keyboard input local. | Stable intervals, 10,000 stale-focus transitions, and 100,000 type-ahead and media-key bypass checks. |
| Repository | Dashboard reads skip unchanged files. | The full load path is traced and the modification-time early return is checked. |
| Git | Usage collection owns the repository and Git subprocess pipeline. | The asynchronous utility process has one end-to-end interval and structured phase events. |
| GitHub | Contributor data uses a daily cache and failure fallback. | Cache and request intervals plus a one-read fallback test. |
| Extension discovery | Readiness is requested on demand and aggregate reports run concurrently. | The settings readiness request is traced. |
| UI rendering | Clipboard history renders at most 80 rows, and inactive terminal surfaces defer redraws. | A 20,000-chunk terminal flood produces one deferred redraw before activation. |
| Cache | Contributor hit and miss decisions are visible. | Corrupt-cache fallback decodes once. |
| Background workers | Usage collection runs as a utility process and handles task cancellation. | The complete worker lifetime is traced by `usage.refresh`. |
| Generation safety | Local and remote project refreshes reject canceled or superseded results. | Deterministic concurrency tests complete requests out of order. |
| Memory | Helper CPU, RSS, and optional idle wakeups have a machine-readable sampler. | Fixture tests lock schema, percentiles, and units. |
| Main thread | Every runtime interval records its begin and end thread context. | A deterministic test checks the main-thread signal. |
| Large repository | Dashboard JSON decoding is detached, but aggregation returns to the main actor. | Decode placement is checked and aggregation has its own interval. |
| Slow network | GitHub contributor requests stop after ten seconds and retain cached output. | Timeout source evidence and a local failing-network test. |

No universal timing budget is checked because CPU, RSS, disk, and network timing
vary materially by hardware and environment. Stable regression properties are
checked in CI. Terminal regressions also use broad responsiveness ceilings with
at least an order of magnitude of headroom over the captured development run.
Timing changes are compared on the same machine, build, data set, power mode,
and network profile.

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

Use the App Launch template for `applicationDidFinishLaunching` and initial-frame
comparisons. Keep helper extension flags and isolated defaults identical across
runs, and compare the `helper.services.*` intervals to find individual main-thread
bursts.

For large-repository comparisons, reuse the same `usage.json` and record
`dashboard.load` and `dashboard.ingest`. For slow-network comparisons, apply the
same Network Link Conditioner profile and record `contributors.fetch`.

For terminal comparisons, open several Machine, Workspace, Quinjet, and Herdr
tabs, stream output in each, then switch repeatedly between them. Inactive tabs
should stop drawing, the selected tab should render its latest buffer once, and
keyboard focus should stay with the latest selected terminal.

The deterministic harness can be verified without a running app:

```sh
make ci-performance
```

The same gate compares changed Swift production files with the selected base revision. It
rejects newly introduced blocking file or process work on the main actor, fire-and-forget
detached tasks, direct process launches, unbounded process capture and remote fan-out,
unguarded state publication after suspension, and unbounded main-actor projection chains.
Existing occurrences are a ratcheted baseline, so unchanged or removed legacy code does not
require a path or symbol allowlist. New subprocess work should reuse a bounded runner, and
repeated UI work should own and cancel its task before applying only the latest result.

Further refactors should follow captured regressions. The first candidates are
shared extension-probe snapshots and service-specific background preparation if
their intervals show material cost.
