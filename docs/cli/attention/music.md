# `ed attention music`

Summarizes observed audio playback by track, artist, album, service, and listening
time.

```
ed attention music [--range <window>] [--limit <count>] [--json]
```

The default range is `7d` and the default limit is 25 tracks. Pass `--limit 0`
for all tracks. Music remains a separate listening dimension and is not treated as
the primary application merely because playback continued in the background.

Deep mode in the browser extension is required for browser media metadata. Native
application tracking still records the foreground music application as ordinary
attention when it is actually in front.

## Where to go next

- [CLI index](../README.md)
- [`ed attention summary`](./summary.md)
