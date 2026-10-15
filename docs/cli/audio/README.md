# `ed audio`

Per-app volume for whatever is playing, the same sliders as the notch mixer.
Turning the mixer on or off stays `ed config` (`notchAudioMixerEnabled`).

```
ed audio ls [--json]
ed audio volume <app> <level> [--json]
ed audio mute <app> [--json]
ed audio unmute <app> [--json]
```

`<app>` is a name, a bundle id, or a process id. `<level>` is 0 to 100. 0 mutes
the app. 100 restores full volume and removes the tap. These commands need the
Edith menu bar app, and macOS 14.4 or later.

`ls` prints one app per line: name, bundle id, and either `muted` or the
percent. `--json` returns `apps` and `changed`.

## Where to go next

- [`ed config`](../config/README.md) for the mixer switch.
- [All `ed` commands](../README.md).
