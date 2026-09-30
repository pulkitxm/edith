# Native video editor performance

The interactive composition uses a maximum dimension of 1280 pixels. A
2160x3840 project previews at 720x1280 while delivery retains the requested
canvas. Preview rebuilds debounce for 40 ms and cancel superseded work. Exact
seeks keep only the latest pending target. Transport observations are separate
from clip-lane observations, and undo history retains the latest 128 edits.

## Native resource comparison

The opt-in `VideoEditorBenchmarkTests` ran on a MacBook Pro with M4 Pro using a
47-shot synthetic still-image project at 2160x3840 and 60 fps. Each mode ran in
a fresh test process. Playback measurements cover eight seconds after a
one-second warmup; scrubbing covers 20 targets across the timeline.

| Measurement | Full-resolution preview | Bounded preview |
| --- | ---: | ---: |
| Preview canvas | 2160x3840 | 720x1280 |
| Initial composition build | 451.9 ms | 415.6 ms |
| Median exact-seek readback | 3.14 ms | 3.11 ms |
| P95 exact-seek readback | 11.54 ms | 10.02 ms |
| Observed video-output frames/sec | 59.97 | 60.09 |
| Process CPU time during playback | 3.66 s | 3.21 s |
| Peak process physical footprint | 807.3 MB | 286.0 MB |

Physical footprint fell by 64.6%, and measured CPU time fell by 12.4%. These are
native AVPlayer decoding/composition measurements, not end-to-end UI latency.
The process footprint includes the test runtime. Local AVPlayer access logs did
not report a dropped-frame counter, so no zero-drop claim is inferred from it.

A separate 20.93-second native Metal System Trace of the development editor
during synthetic playback recorded 2399 GPU execution intervals. Their union
was 0.694 seconds, or 3.31% of the capture. Compute intervals averaged 289
microseconds, with P95 of 653 microseconds. There were no recorded hangs over
100 ms. This is process-attributed execution time, not a hardware utilization
counter.

A 45-second Animation Hitches capture during playback and verified timeline
scale changes to 160, 40, 240 and 80 recorded one 40.02 ms hitch. The nine
flagged app-update intervals averaged 6.86 ms. This capture includes preview and
inspector work, so it does not isolate a timeline-only frame-time budget.

## Reproduction

Build the test products once, then run each dimension in a separate process:

```sh
cd Packages/Edith
EDITH_EDITOR_BENCHMARK_PROJECT=/absolute/synthetic.openscreen \
EDITH_EDITOR_BENCHMARK_OUTPUT=/absolute/bounded-result.json \
EDITH_EDITOR_BENCHMARK_DIMENSION=1280 \
./test.sh --skip-build --filter '^EdithTests\.VideoEditorBenchmarkTests'
```

Use dimension `3840` and a different result path for the full-resolution
comparison. Select the installed Xcode toolchain if the system default points
to Command Line Tools. The benchmark is disabled in ordinary test runs and
records its measurement scope in each result.

Structural regressions are checked with `make ci-performance`. Supply the
explicit comparison commit, for example `PERFORMANCE_BASE=origin/main`, when
checking uncommitted changes. Transport tests additionally verify 1000 pending
scrub targets yield two exact seeks and 600 playhead updates leave clip lanes
uninvalidated.
