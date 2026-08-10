# `ed companion baselines`

Your own delivery baselines: the median and spread of every measured signal, bucketed
by recording context and language, which every deviation is scored against.

Usage:

```
ed companion baselines [--json] [--endpoint <url>]
```

Absolute acoustic values are close to meaningless. A hundred and forty words a minute
is fast for one person and slow for another. But this is a system holding thousands of
hours of exactly one speaker, so the comparison is against your own history rather
than a population, and that turns weak features into strong ones. "Speech rate 2.1
below your own baseline, sustained for four minutes" is auditable and personal in a
way no general model could produce.

Buckets matter as much as the numbers. A different microphone or room shifts energy
and pitch estimates more than mood does, and your baseline in English is not your
baseline in Hindi, so signals are compared only within their own bucket.

Until about twenty hours of audio have accumulated, deviations are suppressed
entirely and this command says so. Showing deviations against four recordings would be
noise wearing a number.

`--json` shape: `{audioSeconds, coldStart, baselines: [{kind, contextBucket, median,
iqr, samples}]}`.

These numbers are plumbing, not a dashboard. They exist so the system notices where to
look and can justify what it says, not so you can watch a daily score.

## Where to go next

- [`ed companion episode`](./episode.md), where the signals sit against a transcript
- [`ed companion`](./README.md), the rest of this group
- [All `ed` commands](../README.md)
