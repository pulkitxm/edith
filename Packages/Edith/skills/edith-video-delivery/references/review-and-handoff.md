# Review and handoff

## Choose frames that answer questions

Use `frame --help` and, if advertised, `contact-sheet --help`. Pick times from the
rendered output after trim, speed and sequence changes. For output rate `p/q`,
frame `n` begins at `n*q/p` seconds. A sequence of `N` frames ends after frame
`N-1`; its duration is not a valid last-frame sample.

Review both sides of each important edit, plus the middle of transitions, caption
entrances and exits, reframing and music cues. Record exact selected frames from
the CLI's report when available. Some time-based sampling floors to the preceding
frame. A decimal time near a boundary can select the earlier frame, so confirm
the returned index instead of relying on a rounded label.

Inspect the image files with an image-reading tool. Check that text is readable,
subjects remain in frame, expected effects are present, and no unexpected blank
frames or orientation changes appear. A contact sheet is a compact review aid,
not proof that all frames are correct. Review extracted frames from the actual
movie too: a native preview and a final encode are separate artifacts.

## Review the sound with explicit limits

Verify exported audio streams, sample rate, channels and duration against the
brief. Inspect gain, peaks or loudness and expected silence intervals with
available tools. Check voiceover and beat cues against output-frame positions.
Do not claim an audible review if only metadata or waveforms were available.
In a headless run, mark listening checks pending if no listening tool is present.

## Make the handoff reproducible

Keep a local delivery ledger with project identity, source identities and paths,
plan and settings, output path/checksum, measured media properties and review
samples. Record both successful checks and unresolved limitations.

An editable document referencing absolute source paths is not a self-contained
package. Check dependencies before handoff. If a supported collection or relink
operation exists, discover it and validate the collected copy. A project clone
alone does not copy its media or necessarily preserve external usage reservations.

A compact completion report can use these fields:

| Field | Content |
| --- | --- |
| Editable cut | Project path and variant |
| Final delivery | File path, checksum and measured properties |
| Review | Contact sheet or sampled images and exact output frames |
| Dependencies | Original media required for further edits |
| Acceptance | Passed checks, failed checks and unverified judgments |

Only include artifacts that actually exist. Keep local paths and real media out
of public evidence. When sharing a demonstration, create fresh synthetic media,
run the real workflow on it, and sanitize the resulting ledger or terminal text.
