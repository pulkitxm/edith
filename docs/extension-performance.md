# Extension performance

`ed extensions ls --json` reports how long each installed extension took to
load, per role. The `bundles` entry covers signature verification of every
role bundle before start. Role entries (`app`, `helper`, `agent`) cover
loading and starting the code, the first presentation and its first frame.

| Field | Meaning |
| --- | --- |
| `verifyMs` | Code signature checks for the extension's bundles, including time queued behind other extensions (four run at once) and waiting for the main thread during launch. A bundle whose files are unchanged since its last full check skips the check itself. |
| `startMs` | Loading the bundle, describing it and running its `start` on the main thread. |
| `readyAfterLaunchMs` | When the role finished starting, measured from process launch. |
| `presentationMs` | Creating the view controller for the first presentation. |
| `firstFrameMs` | From the presentation request until the view is in a window and the main thread is free. |
| `presentedAfterLaunchMs` | When the first frame happened, measured from process launch. |

Timings reset when an extension restarts. Each phase is also logged under the
`com.pulkit.edith` subsystem, category `extension-load`:

```sh
log stream --predicate 'subsystem == "com.pulkit.edith" AND category == "extension-load"'
```

## Measuring

Build this worktree's development app, install the extensions to measure into
its slot, then run the cold launch benchmark. It relaunches the development
build in the background and prints the median of each field.

```sh
./build.sh --no-open
dist/Edith.app/Contents/MacOS/ed extensions install <id>
make dev-extension-timings RUNS=5
```

To time first opens, reveal pages in the background and read `firstFrameMs`:

```sh
dist/Edith.app/Contents/MacOS/ed app reveal studio
dist/Edith.app/Contents/MacOS/ed extensions info studio --json
```

## Baseline

Measured on 2026-11-01 from v0.0.370 (host ABI `edith-host-6`), development
build, Apple M4 Pro, macOS 27.0.1, with 17 extensions installed and enabled.
Median of five cold launches:

| Extension | Role | verifyMs | startMs | readyAfterLaunchMs |
| --- | --- | ---: | ---: | ---: |
| blitztree | app | 24.9 | 5.6 | 620.4 |
| colorPicker | helper | 32.9 | 6.3 | 633.4 |
| database | app | 386.1 | 15.1 | 993.6 |
| docs | app | 42.9 | 7.4 | 643.8 |
| emoji | helper | 53.1 | 110.5 | 782.9 |
| herdr | app | 194.9 | 11.8 | 818.0 |
| jev | app | 183.3 | 6.0 | 793.3 |
| keepAwake | helper | 172.7 | 6.0 | 802.8 |
| latex | app | 206.3 | 6.7 | 827.6 |
| notchShelf | helper | 227.2 | 6.8 | 838.0 |
| plugins | app | 225.0 | 32.2 | 873.0 |
| quinjet | app | 390.3 | 6.7 | 1002.9 |
| seoAudit | app | 269.9 | 7.4 | 884.9 |
| studio | app | 352.8 | 13.7 | 975.8 |
| system | app | 278.5 | 23.1 | 911.3 |
| systemStats | helper | 312.7 | 14.2 | 958.3 |
| terminal | app | 393.1 | 5.8 | 1011.9 |

Totals: 288 ms of main-thread start work, and every extension ready 1012 ms
after launch.

First opens in the background (`ed app reveal`, one launch): docs 48 ms,
notchShelf card 36 ms, database 75 ms, studio 111 ms (`firstFrameMs`).

Starting an extension right after installing it took 405 to 950 ms on the main
thread (`startMs`), against 6 to 110 ms when the same package starts at launch.

### Reading the baseline

- Every enabled extension starts at launch. Signature verification is the
  largest cost, and because extensions share a four-wide queue, the last one
  becomes ready about a second after launch. Launch cost grows with every
  installed extension.
- Start work itself is small once the binary is cached. The first start after
  an install is the slow path and blocks the main thread for up to a second.
- Each package embeds its own copy of the shared support libraries, which
  these timings do not show directly; package size and duplicated classes are
  tracked separately.

## After on-demand start

Measured on 2026-11-02 from this branch (host ABI `edith-host-8`, shared
extension kit), development build, same Mac and the same 17 extensions
installed and enabled. Median of five cold launches with the default Home
layout:

| Extension | Role | verifyMs | startMs | readyAfterLaunchMs |
| --- | --- | ---: | ---: | ---: |
| herdr | app | 26.8 | 13.9 | 609.9 |
| keepAwake | helper | 7.4 | 4.2 | 585.5 |
| notchShelf | helper | 16.5 | 5.8 | 608.5 |
| system | app | 39.5 | 20.5 | 633.1 |
| systemStats | helper | 63.7 | 13.6 | 650.0 |

Idle until first use: blitztree, colorPicker, database, docs, emoji, jev,
latex, plugins, quinjet, seoAudit, studio and terminal. Keep Awake and System
start because their actions card is on the default Home layout.

Totals: 57 ms of main-thread start work (baseline 288 ms), and every launch
extension ready 650 ms after launch (baseline 1012 ms).

First opens in the background, median of five cold launches, now including
starting the idle extension: docs 51 ms, database 68 ms, studio 84 ms
(`firstFrameMs`; baseline 48, 75 and 111 ms with the extension already
running). Once an extension is running, the same opens take docs 16 ms and
studio 79 ms. Every install above became active without a restart.

With docs on the shared extension service runtime (host `edith-host-9`), docs
opens in 41 ms (`firstFrameMs`, median of five background cold launches,
including starting the idle extension), against 48 ms in the baseline.
